#!/usr/bin/env python3
"""Play an RZX file on a NextTang board in 48K Spectrum mode.

Needs an image built with the RZX player (Nano 20K: build_zxnext.sh --rzx 2
or 3) and the debugger on the debug UART (--pi-pins 0). The board must
already be a 48K Spectrum (NextZXOS's 48K BASIC). On the debug UART the tool:

1. pauses the CPU, writes the recording's first snapshot (a 48K .szx, as
   Fuse embeds, or a 48K .z80 of any version) into RAM at 0x4000-0xFFFF and into the CPU's registers; later
   snapshots in the file (Fuse's autosaves) are not needed and are skipped;
2. sends P and the first frames of the recording, which arms the player, and
   resumes the CPU: playing starts at that instruction;
3. sends the rest as the board plays it, keeping the board's 1024-byte buffer
   topped up from the frame counts the board reports;
4. ends the stream and reads the board's result: the frames played and
   whether the replay went out of step (desync).

While playing, every port read the CPU makes returns the recorded byte and
its maskable interrupt comes at the recorded instruction, so the keyboard
does nothing and the program runs as it did when recorded.

With --until FRAME the replay stops after that many frames and the machine
carries on live from there, keys and all: a rewind to that frame, or a
take-over of someone else's game. With --speed the CPU runs faster while
playing (the replay does not depend on the machine's timing), which makes
getting to a far frame quick.

divMMC automapping is turned off for the replay (see rzx_capture.py) and put
back afterwards. The interrupt mode cannot be written through the debugger,
so if the board's differs from the snapshot's the tool runs an IM instruction
in RAM first.
"""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import termios
import zlib
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "host/debug"))
from nexttang_debug.protocol import CMD_CPU_RESUME, CPU_STATE_WRITE, PiDebug, Z80Memory  # noqa: E402
from nexttang_debug.uart import UartLink  # noqa: E402
from tools.rzx import Frame, read  # noqa: E402

DEFAULT_PORT = "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A5069RR4-if00-port0"
PAGES_48K = [0xFF, 0xFF, 0x0A, 0x0B, 0x04, 0x05, 0x00, 0x01]
SPEEDS = {"3.5": 0, "7": 1, "14": 2, "28": 3}      # NextREG 0x07 bits 1:0
BUFFER = 1024
KEEP_FREE = 256          # never fill the board's buffer past BUFFER - KEEP_FREE
PREFILL_MAX = 255


def _z80_unpack(data: bytes, length: int | None = None) -> bytes:
    """Undo the .z80 run-length coding (ED ED count byte); in a version 1
    file the block ends at 00 ED ED 00."""
    out = bytearray()
    at = 0
    while at < len(data) and (length is None or len(out) < length):
        if length is None and data[at:at + 4] == b"\x00\xed\xed\x00":
            break
        if data[at:at + 2] == b"\xed\xed" and at + 3 < len(data):
            out += bytes([data[at + 3]]) * data[at + 2]
            at += 4
        else:
            out.append(data[at])
            at += 1
    return bytes(out)


def parse_z80(data: bytes) -> tuple[dict[str, int], bytes]:
    """Registers and the 48K of RAM from a 48K .z80, versions 1 to 3."""
    if len(data) < 30:
        raise ValueError("not a .z80 snapshot")
    (a, f, bc, hl, pc, sp, i, r, flags, de, bc_, de_, hl_, a_, f_, iy, ix,
     iff1, iff2, mode) = struct.unpack("<BBHHHHBBBHHHHBBHHBBB", data[:30])
    if flags == 0xFF:
        flags = 1
    if pc != 0:                                   # version 1
        body = data[30:]
        ram = _z80_unpack(body) if flags & 0x20 else body
    else:                                         # versions 2 and 3
        extra = struct.unpack_from("<H", data, 30)[0]
        pc = struct.unpack_from("<H", data, 32)[0]
        hardware = data[34]
        if hardware not in ((0, 1) if extra == 23 else (0, 1, 3)) or (len(data) > 37 and data[37] & 0x80):
            raise ValueError(f"the .z80 is not for a 48K Spectrum (hardware {hardware})")
        pages: dict[int, bytes] = {}
        at = 32 + extra
        while at + 3 <= len(data):
            size, page = struct.unpack_from("<HB", data, at)
            at += 3
            if size == 0xFFFF:
                pages[page] = data[at:at + 0x4000]
                at += 0x4000
            else:
                pages[page] = _z80_unpack(data[at:at + size], 0x4000)
                at += size
        if any(len(pages.get(n, b"")) != 0x4000 for n in (8, 4, 5)):
            raise ValueError("the .z80 lacks one of the 48K RAM pages")
        ram = pages[8] + pages[4] + pages[5]
    if len(ram) != 0xC000:
        raise ValueError("the .z80 does not hold 48K of RAM")
    regs = {"AF": a << 8 | f, "BC": bc, "DE": de, "HL": hl, "AF'": a_ << 8 | f_, "BC'": bc_,
            "DE'": de_, "HL'": hl_, "IX": ix, "IY": iy, "SP": sp, "PC": pc, "I": i,
            "R": r & 0x7F | (flags & 1) << 7, "IFF1": 1 if iff1 else 0, "IFF2": 1 if iff2 else 0,
            "IM": mode & 3}
    return regs, ram


def parse_szx_48k(data: bytes) -> tuple[dict[str, int], bytes]:
    """Registers and the 48K of RAM from a 48K Spectrum .szx (ZX-State), the
    snapshot Fuse embeds in its recordings."""
    if data[:4] != b"ZXST":
        raise ValueError("not an .szx snapshot")
    if data[6] not in (0, 1):
        raise ValueError(f"the .szx is not for a 16K or 48K Spectrum (machine {data[6]})")
    regs = None
    pages: dict[int, bytes] = {}
    at = 8
    while at + 8 <= len(data):
        name, size = data[at:at + 4], struct.unpack_from("<I", data, at + 4)[0]
        body = data[at + 8:at + 8 + size]
        at += 8 + size
        if name == b"Z80R":
            (af, bc, de, hl, af_, bc_, de_, hl_, ix, iy, sp, pc, i, r, iff1, iff2, mode) = \
                struct.unpack_from("<12H5B", body)
            if body[34] & 2:
                raise ValueError("the snapshot's CPU is halted; not supported yet")
            regs = {"AF": af, "BC": bc, "DE": de, "HL": hl, "AF'": af_, "BC'": bc_, "DE'": de_,
                    "HL'": hl_, "IX": ix, "IY": iy, "SP": sp, "PC": pc, "I": i, "R": r,
                    "IFF1": 1 if iff1 else 0, "IFF2": 1 if iff2 else 0, "IM": mode & 3}
        elif name == b"RAMP":
            flags, page = struct.unpack_from("<HB", body)
            raw = body[3:]
            pages[page] = zlib.decompress(raw) if flags & 1 else raw
    if regs is None or any(len(pages.get(n, b"")) != 0x4000 for n in (5, 2, 0)):
        raise ValueError("the .szx lacks the registers or one of RAM pages 5, 2 and 0")
    return regs, pages[5] + pages[2] + pages[0]


IM_OPCODES = {0: b"\xed\x46", 1: b"\xed\x56", 2: b"\xed\x5e"}


def set_interrupt_mode(debug: PiDebug, memory: Z80Memory, mode: int, scratch: int = 0xC000) -> None:
    """The debugger cannot write the interrupt mode, so run an IM instruction:
    put it in RAM, point PC at it and single-step. The caller writes RAM and
    the registers afterwards, so nothing needs putting back."""
    memory.write(scratch, IM_OPCODES[mode] + b"\x00\x00")
    debug.set_register("PC", scratch)
    for _ in range(2):                      # a step may stop between ED and the opcode
        debug.step()
        if debug.registers()["IM"] == mode:
            return
    raise RuntimeError(f"could not put the CPU in IM {mode}")


def frame_bytes(frame: Frame) -> bytes:
    return struct.pack("<HH", frame.fetches, len(frame.inputs)) + frame.inputs


def escaped(data: bytes) -> bytes:
    return data.replace(b"\xfe", b"\xfe\x00")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("recording", type=Path, help="the .rzx to play")
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--prefill", type=int, default=PREFILL_MAX,
                        help="most bytes to send ahead of the resume (0 to 255)")
    parser.add_argument("--until", type=int, default=None, metavar="FRAME",
                        help="stop after this many frames and hand the machine back live there: "
                             "with the keys free again, this is a rewind to that frame")
    parser.add_argument("--speed", choices=sorted(SPEEDS, key=float), default=None,
                        help="CPU speed in MHz while playing (the replay does not depend on it); "
                             "put back afterwards")
    parser.add_argument("--keep-divmmc", action="store_true",
                        help="leave divMMC automapping as it is")
    args = parser.parse_args(argv)

    rzx = read(args.recording)
    if not rzx.snapshots or not rzx.snapshots[0].data:
        print("the recording has no embedded snapshot", file=sys.stderr)
        return 1
    first = rzx.snapshots[0]
    try:
        if first.extension.upper() == "SZX":
            regs, ram = parse_szx_48k(first.data)
        elif first.extension.upper() == "Z80":
            regs, ram = parse_z80(first.data)
        else:
            raise ValueError(f"no reader for a .{first.extension.lower()} snapshot")
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    frames = rzx.frames()
    if args.until is not None:
        if not 0 < args.until <= len(frames):
            print(f"--until must be 1 to {len(frames)}", file=sys.stderr)
            return 1
        frames = frames[:args.until]
    sizes = [4 + len(f.inputs) for f in frames]
    if max(sizes) > BUFFER - KEEP_FREE:
        print(f"a frame has {max(sizes) - 4} port reads: more than the board's buffer takes", file=sys.stderr)
        return 1

    with UartLink(args.port, 115200, timeout=2.0) as link:
        debug = PiDebug(link)
        nr0a = debug.nextreg(0x0A)
        if nr0a & 0x10 and not args.keep_divmmc:
            debug.set_nextreg(0x0A, nr0a & ~0x10)
            print(f"divMMC automap off (NextREG 0x0A {nr0a:02X} -> {nr0a & ~0x10:02X}) for the replay")
            time.sleep(1.0)
        debug.pause()
        nr07 = debug.nextreg(0x07) & 3
        memory = Z80Memory(debug)
        pages = memory.pages()
        now = debug.registers()
        problem = None
        if pages != PAGES_48K:
            problem = f"not the 48K memory map: MMU {' '.join(f'{p:02X}' for p in pages)}"
        if problem:
            debug.resume()
            if nr0a & 0x10 and not args.keep_divmmc:
                debug.set_nextreg(0x0A, nr0a)
            print(problem, file=sys.stderr)
            return 1

        if now["IM"] != regs["IM"]:
            set_interrupt_mode(debug, memory, regs["IM"])
            print(f"interrupt mode set: IM {now['IM']} -> IM {regs['IM']}")
        memory.write(0x4000, ram)
        for name in ("AF", "BC", "DE", "HL", "AF'", "BC'", "DE'", "HL'", "IX", "IY", "SP", "PC", "I", "R"):
            debug.set_register(name, regs[name])
        debug.set_cpu_register(CPU_STATE_WRITE, regs["IFF2"] << 1 | regs["IFF1"])   # not halted
        check = debug.registers()
        wrong = [n for n in ("AF", "BC", "DE", "HL", "IX", "IY", "SP", "PC", "I", "IM", "IFF1", "IFF2", "HALT")
                 if check[n] != (regs[n] if n != "HALT" else 0)]
        if wrong or memory.read(0x4000, 0x100) != ram[:0x100] or memory.read(0xFF00, 0x100) != ram[-0x100:]:
            debug.resume()
            print(f"the snapshot did not go in (registers that differ: {wrong})", file=sys.stderr)
            return 1
        if args.speed is not None and SPEEDS[args.speed] != nr07:
            debug.set_nextreg(0x07, SPEEDS[args.speed])
            print(f"CPU speed {args.speed} MHz for the replay (NextREG 0x07 {nr07} -> {SPEEDS[args.speed]})")
        print(f"snapshot in: PC {regs['PC']:04X} SP {regs['SP']:04X} IM {regs['IM']} IFF1 {regs['IFF1']}; "
              f"{len(frames)} frames to play")

        # Arm with as many whole frames as fit in the prefill, then resume
        # without waiting for the reply: from the resume on, the UART is the
        # player's.
        fd = link.fd
        sent = 0                 # frames handed to the board
        prefill = b""
        while sent < len(frames) and len(prefill) + sizes[sent] <= min(args.prefill, PREFILL_MAX):
            prefill += frame_bytes(frames[sent])
            sent += 1
        sent_bytes = len(prefill)
        os.write(fd, b"P" + bytes([len(prefill)]) + prefill)
        termios.tcdrain(fd)
        time.sleep(0.05)
        # A one-byte frame: playing starts when the resume is carried out,
        # and any byte after it would be taken as the recording.
        os.write(fd, b"X\x01" + bytes([CMD_CPU_RESUME]))
        termios.tcdrain(fd)
        time.sleep(0.002)                       # at 28 MHz the pre-filled frames last 50 ms
        termios.tcflush(fd, termios.TCIFLUSH)   # what is left of the resume's reply

        started = time.monotonic()
        done = 0                 # frames the board says have ended
        done_bytes = 0
        ended = False
        tail = bytearray()
        result = None
        while result is None:
            # top the buffer up with whole frames
            out = b""
            while sent < len(frames) and sent_bytes - done_bytes + sizes[sent] <= BUFFER - KEEP_FREE:
                out += escaped(frame_bytes(frames[sent]))
                sent_bytes += sizes[sent]
                sent += 1
            if sent == len(frames) and not ended:
                out += b"\xff\xff\x00\x00" + b"\xfe\x01"   # a header that is not played, then the end
                ended = True
            if out:
                os.write(fd, out)
            ready, _, _ = select.select([fd], [], [], 0.02)
            if ready:
                for value in os.read(fd, 4096):
                    if tail or value & 0xF8 == 0x80:
                        tail.append(value)
                        if len(tail) == 3:
                            result = (tail[0] & 7, tail[1] | tail[2] << 8)
                            break
                    elif value & 0x40:
                        step = (value - done) & 0x3F
                        for _ in range(step):
                            if done < len(frames):
                                done_bytes += sizes[done]
                            done += 1
            if time.monotonic() - started > len(frames) / 45 + 10:
                print("no result from the board", file=sys.stderr)
                break
        seconds = time.monotonic() - started

    # Put things back: the CPU speed at once (the machine is live again), and
    # divMMC automapping unless the machine was handed over mid-recording,
    # where the program now running is the recording's, not NextZXOS's.
    restore_speed = args.speed is not None and SPEEDS[args.speed] != nr07
    restore_divmmc = bool(nr0a & 0x10) and not args.keep_divmmc and args.until is None
    if restore_speed or restore_divmmc:
        time.sleep(0.05)
        with UartLink(args.port, 115200, timeout=2.0) as link:
            debug = PiDebug(link)
            if restore_speed:
                debug.set_nextreg(0x07, nr07)
                print(f"CPU speed put back (NextREG 0x07 {nr07})")
            if restore_divmmc:
                time.sleep(0.5)
                debug.set_nextreg(0x0A, nr0a)
                print(f"NextREG 0x0A restored to {nr0a:02X}")
    if nr0a & 0x10 and not args.keep_divmmc and args.until is not None:
        print(f"divMMC automap left off (NextREG 0x0A was {nr0a:02X}): the machine is live in the recording")

    if result is None:
        return 1
    flags, played = result
    print(f"board: {played} of {len(frames)} frames played in {seconds:.1f} s; "
          f"desync {flags & 1}, buffer overflow {flags >> 1 & 1}, ended by host {flags >> 2 & 1}")
    ok = flags == 4 and played == len(frames)
    print("REPLAY OK" if ok else "REPLAY FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
