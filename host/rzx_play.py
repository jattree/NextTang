#!/usr/bin/env python3
"""Play an RZX file on a NextTang board in 48K Spectrum mode.

Needs an image built with the RZX player (Nano 20K: build_zxnext.sh --rzx 2
or 3) and the debugger on the debug UART (--pi-pins 0). The board must
already be a 48K Spectrum in the recording's interrupt mode (NextZXOS's 48K
BASIC, for a recording made there). On the debug UART the tool:

1. pauses the CPU, writes the recording's snapshot (a version 1,
   uncompressed 48K .z80, as host/rzx_capture.py writes) into RAM at
   0x4000-0xFFFF and into the CPU's registers;
2. sends P and the first frames of the recording, which arms the player, and
   resumes the CPU: playing starts at that instruction;
3. sends the rest as the board plays it, keeping the board's 1024-byte buffer
   topped up from the frame counts the board reports;
4. ends the stream and reads the board's result: the frames played and
   whether the replay went out of step (desync).

While playing, every port read the CPU makes returns the recorded byte and
its maskable interrupt comes at the recorded instruction, so the keyboard
does nothing and the program runs as it did when recorded.

divMMC automapping is turned off for the replay (see rzx_capture.py) and put
back afterwards. The interrupt mode cannot be written through the debugger,
so the tool refuses if the board's differs from the snapshot's.
"""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import termios
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
BUFFER = 1024
KEEP_FREE = 256          # never fill the board's buffer past BUFFER - KEEP_FREE
PREFILL_MAX = 255


def parse_z80_v1(data: bytes) -> tuple[dict[str, int], bytes]:
    """Registers and the 48K of RAM from a version 1, uncompressed .z80."""
    if len(data) != 30 + 0xC000:
        raise ValueError("not an uncompressed 48K version 1 .z80")
    (a, f, bc, hl, pc, sp, i, r, flags, de, bc_, de_, hl_, a_, f_, iy, ix,
     iff1, iff2, mode) = struct.unpack("<BBHHHHBBBHHHHBBHHBBB", data[:30])
    if pc == 0 or flags & 0x20:
        raise ValueError("only version 1, uncompressed .z80 snapshots are supported")
    regs = {"AF": a << 8 | f, "BC": bc, "DE": de, "HL": hl, "AF'": a_ << 8 | f_, "BC'": bc_,
            "DE'": de_, "HL'": hl_, "IX": ix, "IY": iy, "SP": sp, "PC": pc, "I": i,
            "R": r & 0x7F | (flags & 1) << 7, "IFF1": 1 if iff1 else 0, "IFF2": 1 if iff2 else 0,
            "IM": mode & 3}
    return regs, data[30:]


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
    parser.add_argument("--keep-divmmc", action="store_true",
                        help="leave divMMC automapping as it is")
    args = parser.parse_args(argv)

    rzx = read(args.recording)
    if not rzx.snapshots or rzx.snapshots[0].extension.upper() != "Z80":
        print("the recording has no .z80 snapshot", file=sys.stderr)
        return 1
    regs, ram = parse_z80_v1(rzx.snapshots[0].data)
    frames = rzx.frames()
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
        memory = Z80Memory(debug)
        pages = memory.pages()
        now = debug.registers()
        problem = None
        if pages != PAGES_48K:
            problem = f"not the 48K memory map: MMU {' '.join(f'{p:02X}' for p in pages)}"
        elif now["IM"] != regs["IM"]:
            problem = f"the board is in IM {now['IM']}, the snapshot in IM {regs['IM']}"
        if problem:
            debug.resume()
            if nr0a & 0x10 and not args.keep_divmmc:
                debug.set_nextreg(0x0A, nr0a)
            print(problem, file=sys.stderr)
            return 1

        memory.write(0x4000, ram)
        for name in ("AF", "BC", "DE", "HL", "AF'", "BC'", "DE'", "HL'", "IX", "IY", "SP", "PC", "I", "R"):
            debug.set_register(name, regs[name])
        debug.set_cpu_register(CPU_STATE_WRITE, regs["IFF2"] << 1 | regs["IFF1"])   # not halted
        check = debug.registers()
        wrong = [n for n in ("AF", "BC", "DE", "HL", "IX", "IY", "SP", "PC", "I", "IFF1", "IFF2", "HALT")
                 if check[n] != (regs[n] if n != "HALT" else 0)]
        if wrong or memory.read(0x4000, 0x100) != ram[:0x100] or memory.read(0xFF00, 0x100) != ram[-0x100:]:
            debug.resume()
            print(f"the snapshot did not go in (registers that differ: {wrong})", file=sys.stderr)
            return 1
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
        time.sleep(0.06)
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
                    if tail or value & 0x80:
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

    if nr0a & 0x10 and not args.keep_divmmc:
        time.sleep(0.5)
        with UartLink(args.port, 115200, timeout=2.0) as link:
            PiDebug(link).set_nextreg(0x0A, nr0a)
        print(f"NextREG 0x0A restored to {nr0a:02X}")

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
