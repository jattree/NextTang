#!/usr/bin/env python3
"""Play an RZX file on a NextTang board as a 48K, 128K, +2, +2A or +3 Spectrum.

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
so the tool first runs a few instructions in RAM that set it and end in
HALT, which also leaves the CPU stopped where it starts cleanly at the
snapshot's PC.

A 128K or +2 recording needs that machine's two ROMs, which the Next does
not run: give the folder that holds them with --roms (128-0.rom and
128-1.rom, or plus2-0.rom and plus2-1.rom, 16K each, as an emulator ships
them). Starting from the same 48K BASIC, the tool writes them into the
Next's two alternate ROM pages through the debugger and switches those in
(NextREG 0x8C), selects 128K timing, turns divMMC and the +3 and extended
paging ports off, runs a few instructions in RAM that set the interrupt
mode, the sound chip's registers and port 7FFD as the snapshot has them
(the debugger cannot write those), then loads the eight RAM banks. The
machine stays that 128K afterwards, until it is reset.

A +2A or +3 recording has four ROMs (plus3-0.rom to plus3-3.rom). There are
only two alternate ROM pages, so the tool writes these over the Next's own
four ROM pages instead, and turns port 1FFD on. NextZXOS is then gone from
memory until the board is restarted (reloaded or power-cycled; the SD card
is not touched). A snapshot in the +3's all-RAM paging mode is refused.
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
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "host/debug"))
from nexttang_debug.protocol import CMD_CPU_RESUME, CPU_STATE_WRITE, PiDebug, Z80Memory, z80_target  # noqa: E402
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


@dataclass
class Snapshot128:
    """A 128K, +2, +2A or +3 snapshot: what the board needs to become that
    machine."""
    model: str                 # "128", "plus2" or "plus3" (+2A and +3)
    regs: dict[str, int]
    banks: list[bytes]         # RAM banks 0 to 7, 16K each
    port_7ffd: int
    ay: bytes                  # the sound chip's 16 registers
    ay_register: int           # the register last selected at FFFD
    port_1ffd: int = 0         # +2A and +3 only


ROM_FILES = {"128": ("128-0.rom", "128-1.rom"), "plus2": ("plus2-0.rom", "plus2-1.rom"),
             "plus3": ("plus3-0.rom", "plus3-1.rom", "plus3-2.rom", "plus3-3.rom")}   # +2A and +3
SZX_MODELS = {0: "48", 1: "48", 2: "128", 3: "plus2", 4: "plus3", 5: "plus3", 6: "plus3"}


def z80_model(data: bytes) -> str:
    """The machine a .z80 is for: "48", "128", "plus2", "plus3" or "other"."""
    if len(data) < 30:
        raise ValueError("not a .z80 snapshot")
    if data[6] | data[7]:                          # version 1: PC is in the first header
        return "48"
    extra, hardware = struct.unpack_from("<H", data, 30)[0], data[34]
    modified = len(data) > 37 and bool(data[37] & 0x80)
    if hardware in ((0, 1) if extra == 23 else (0, 1, 3)):
        return "other" if modified else "48"       # modified: a 16K
    if hardware in ((3, 4) if extra == 23 else (4, 5, 6)):
        return "plus2" if modified else "128"
    if hardware == 12:
        return "plus2"
    if hardware in (7, 8, 13):
        return "plus3"
    return "other"


def _z80_registers(data: bytes) -> dict[str, int]:
    (a, f, bc, hl, pc, sp, i, r, flags, de, bc_, de_, hl_, a_, f_, iy, ix,
     iff1, iff2, mode) = struct.unpack("<BBHHHHBBBHHHHBBHHBBB", data[:30])
    if flags == 0xFF:
        flags = 1
    if pc == 0:
        pc = struct.unpack_from("<H", data, 32)[0]
    return {"AF": a << 8 | f, "BC": bc, "DE": de, "HL": hl, "AF'": a_ << 8 | f_, "BC'": bc_,
            "DE'": de_, "HL'": hl_, "IX": ix, "IY": iy, "SP": sp, "PC": pc, "I": i,
            "R": r & 0x7F | (flags & 1) << 7, "IFF1": 1 if iff1 else 0, "IFF2": 1 if iff2 else 0,
            "IM": mode & 3}


def _z80_pages(data: bytes) -> dict[int, bytes]:
    pages: dict[int, bytes] = {}
    at = 32 + struct.unpack_from("<H", data, 30)[0]
    while at + 3 <= len(data):
        size, page = struct.unpack_from("<HB", data, at)
        at += 3
        if size == 0xFFFF:
            pages[page] = data[at:at + 0x4000]
            at += 0x4000
        else:
            pages[page] = _z80_unpack(data[at:at + size], 0x4000)
            at += size
    return pages


def parse_z80_128(data: bytes) -> Snapshot128:
    """A 128K or +2 .z80 (version 2 or 3)."""
    model = z80_model(data)
    if model not in ROM_FILES:
        raise ValueError(f"the .z80 is not for a 128K, +2, +2A or +3 Spectrum ({model})")
    pages = _z80_pages(data)
    if any(len(pages.get(n + 3, b"")) != 0x4000 for n in range(8)):
        raise ValueError("the .z80 lacks one of the eight RAM banks")
    port_1ffd = data[86] if model == "plus3" and struct.unpack_from("<H", data, 30)[0] >= 55 else 0
    return Snapshot128(model, _z80_registers(data), [pages[n + 3] for n in range(8)], data[35],
                       bytes(data[39:55]), data[38] & 0x0F, port_1ffd)


def parse_szx_128(data: bytes) -> Snapshot128:
    """A 128K or +2 .szx (ZX-State)."""
    if data[:4] != b"ZXST":
        raise ValueError("not an .szx snapshot")
    model = SZX_MODELS.get(data[6], "other")
    if model not in ROM_FILES:
        raise ValueError(f"the .szx is not for a 128K, +2, +2A or +3 Spectrum (machine {data[6]})")
    regs = None
    port_7ffd = None
    port_1ffd = 0
    ay, ay_register = bytes(16), 0
    pages: dict[int, bytes] = {}
    at = 8
    while at + 8 <= len(data):
        name, size = data[at:at + 4], struct.unpack_from("<I", data, at + 4)[0]
        body = data[at + 8:at + 8 + size]
        at += 8 + size
        if name == b"Z80R":
            regs = _szx_registers(body)
        elif name == b"SPCR":
            port_7ffd, port_1ffd = body[1], body[2] if model == "plus3" else 0
        elif name == b"AY\x00\x00":
            ay_register, ay = body[1] & 0x0F, bytes(body[2:18])
        elif name == b"RAMP":
            flags, page = struct.unpack_from("<HB", body)
            raw = body[3:]
            pages[page] = zlib.decompress(raw) if flags & 1 else raw
    if regs is None or port_7ffd is None or any(len(pages.get(n, b"")) != 0x4000 for n in range(8)):
        raise ValueError("the .szx lacks the registers, the paging port or one of the eight RAM banks")
    return Snapshot128(model, regs, [pages[n] for n in range(8)], port_7ffd, ay, ay_register, port_1ffd)


def _szx_registers(body: bytes) -> dict[str, int]:
    (af, bc, de, hl, af_, bc_, de_, hl_, ix, iy, sp, pc, i, r, iff1, iff2, mode) = \
        struct.unpack_from("<12H5B", body)
    if body[34] & 2:
        raise ValueError("the snapshot's CPU is halted; not supported yet")
    return {"AF": af, "BC": bc, "DE": de, "HL": hl, "AF'": af_, "BC'": bc_, "DE'": de_,
            "HL'": hl_, "IX": ix, "IY": iy, "SP": sp, "PC": pc, "I": i, "R": r,
            "IFF1": 1 if iff1 else 0, "IFF2": 1 if iff2 else 0, "IM": mode & 3}


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
            regs = _szx_registers(body)
        elif name == b"RAMP":
            flags, page = struct.unpack_from("<HB", body)
            raw = body[3:]
            pages[page] = zlib.decompress(raw) if flags & 1 else raw
    if regs is None or any(len(pages.get(n, b"")) != 0x4000 for n in (5, 2, 0)):
        raise ValueError("the .szx lacks the registers or one of RAM pages 5, 2 and 0")
    return regs, pages[5] + pages[2] + pages[0]


IM_OPCODES = {0: b"\xed\x46", 1: b"\xed\x56", 2: b"\xed\x5e"}


SLED = 8


def setup_routine(mode: int, outs: list[tuple[int, int]], copy_to: int) -> tuple[bytes, int]:
    """Z80 code for what the debugger cannot write: a few NOPs, DI, the
    interrupt mode, then each (port, value) as LD BC / LD A / OUT (C),A in
    order, then the first 16 bytes at address 0 copied to copy_to (to show
    which ROM is in), then HALT. Returns the code and the offset of the
    HALT; the CPU must be found halted just past it afterwards.

    The NOPs and the HALT are for the board's sake. A CPU that the debugger
    stopped at a jump does not start cleanly at a new PC: its first few
    bytes there can be skipped (a fault in the debugger support, fixed in
    t80n.vhd after it was found here; older images still have it).
    Stopped in HALT it does, so the code ends in HALT, and the next start,
    into the snapshot, is clean."""
    code = bytearray(bytes(SLED) + b"\xf3" + IM_OPCODES[mode])
    for port, value in outs:
        code += bytes([0x01, port & 0xFF, port >> 8, 0x3E, value & 0xFF, 0xED, 0x79])
    code += bytes([0x21, 0x00, 0x00, 0x11, copy_to & 0xFF, copy_to >> 8, 0x01, 0x10, 0x00, 0xED, 0xB0])
    return bytes(code) + b"\x76", len(code)


def run_setup(debug: PiDebug, memory: Z80Memory, at: int, mode: int, outs: list[tuple[int, int]]) -> dict[str, int]:
    """Run setup_routine at `at` (RAM) and return the registers afterwards.
    Raises RuntimeError if the CPU does not end halted at its HALT with the
    interrupt mode set, after three tries."""
    code, halt = setup_routine(mode, outs, at + 0x200)
    now: dict[str, int] = {}
    for _ in range(3):
        memory.write(at, code)
        debug.set_cpu_register(CPU_STATE_WRITE, 0)
        debug.set_register("PC", at)
        debug.resume()
        time.sleep(0.05)
        debug.pause()
        now = debug.registers()
        if now["HALT"] and now["PC"] == at + halt + 1 and now["IM"] == mode:
            return now
    raise RuntimeError(f"the set-up code did not run to its end (PC {now['PC']:04X}, IM {now['IM']})")


ALT_ROM0 = 0x18000       # the Next's alternate ROM pages in the 2 MB memory:
ALT_ROM1 = 0x1C000       # ROM 0 (port 7FFD bit 4 clear) and ROM 1 (bit 4 set)
SCRATCH_128 = 0x8000     # RAM bank 2, at 0x8000 whatever port 7FFD says


def write_page(debug: PiDebug, page: int, data: bytes) -> None:
    kind, bank, where = z80_target(page, 0)
    if kind == "bram":
        debug.write_bank_ram(bank, where, data)
    else:
        debug.write_memory(where, data)


def read_page(debug: PiDebug, page: int, offset: int, length: int) -> bytes:
    kind, bank, where = z80_target(page, offset)
    return debug.read_bank_ram(bank, where, length) if kind == "bram" else debug.read_memory(where, length)


def prepare_128k(debug: PiDebug, memory: Z80Memory, snap: Snapshot128, roms: list[bytes],
                 say=print) -> None:
    """Make the paused board the snapshot's 128K, +2, +2A or +3: ROMs,
    timing, ports, interrupt mode, sound chip, paging and RAM. The CPU
    registers are the caller's to write afterwards. Raises RuntimeError if a
    step did not take.

    Two ROMs go into the alternate ROM pages. A +2A's or +3's four go over
    the Next's own four ROM pages (the first 64K of the 2 MB memory), where
    ports 1FFD and 7FFD choose among them as on the real machine; NextZXOS
    is then gone until the board is restarted."""
    four = len(roms) == 4
    if four and snap.port_1ffd & 0x01:
        raise RuntimeError("the snapshot is in the +3's all-RAM paging mode; not handled")
    nr03 = debug.nextreg(0x03)
    if four and nr03 & 0x07 not in (3, 4):
        raise RuntimeError(f"the board's machine type ({nr03 & 7}) does not page four ROMs")
    if four:
        for number, rom in enumerate(roms):
            debug.write_memory(number * 0x4000, rom)
        if any(debug.read_memory(number * 0x4000, 0x4000) != rom for number, rom in enumerate(roms)):
            raise RuntimeError("the ROMs did not go into the ROM pages")
        debug.set_nextreg(0x8C, 0x00)        # no alternate ROM
    else:
        debug.write_memory(ALT_ROM0, roms[0])
        debug.write_memory(ALT_ROM1, roms[1])
        if debug.read_memory(ALT_ROM0, 0x4000) != roms[0] or debug.read_memory(ALT_ROM1, 0x4000) != roms[1]:
            raise RuntimeError("the ROMs did not go into the alternate ROM pages")
        debug.set_nextreg(0x8C, 0x80)        # alternate ROM for reads, not locked to either
    if nr03 & 0x08:                          # display timing locked by the user: unlock
        debug.set_nextreg(0x03, 0x08)
    debug.set_nextreg(0x03, 0xB0 if four else 0xA0)   # +3 or 128K timing, machine type as it is
    ports = debug.nextreg(0x82) | 0x02       # 7FFD on, DFFD off, 1FFD only for four ROMs
    debug.set_nextreg(0x82, (ports | 0x08 if four else ports & ~0x08) & ~0x04 & 0xFF)
    debug.set_nextreg(0x83, debug.nextreg(0x83) & ~0x03 & 0xFF)            # divMMC, Multiface off
    debug.set_nextreg(0x84, debug.nextreg(0x84) | 0x01)                    # the sound chip's ports on
    debug.set_nextreg(0x69, 0x00)            # no Layer 2, no Timex mode
    debug.set_nextreg(0x08, debug.nextreg(0x08) & 0x3F | 0x80)   # 7FFD unlocked, contention on
    debug.set_nextreg(0x8E, 0x08)            # bank 0, ROM 0, normal paging, extended bank bits clear
    say("four ROMs over the Next's ROM pages; +3 timing; divMMC and DFFD off" if four else
        "ROMs in the alternate ROM pages; 128K timing; divMMC, 1FFD and DFFD off")

    outs = []
    for register in range(16):
        outs += [(0xFFFD, register), (0xBFFD, snap.ay[register])]
    outs += [(0xFFFD, snap.ay_register), (0x123B, 0x00)]
    if four:
        outs += [(0x1FFD, snap.port_1ffd)]   # before 7FFD, which may lock both
    outs += [(0x7FFD, snap.port_7ffd)]
    now = run_setup(debug, memory, SCRATCH_128, snap.regs["IM"], outs)
    bank = snap.port_7ffd & 7
    top = [debug.nextreg(0x56), debug.nextreg(0x57)]
    seen = memory.read(SCRATCH_128 + 0x200, 16)
    rom = (snap.port_1ffd >> 1 & 2 if four else 0) | snap.port_7ffd >> 4 & 1
    want = roms[rom][:16]
    locked = not debug.nextreg(0x08) & 0x80
    problems = []
    if top != [bank * 2, bank * 2 + 1]:
        problems.append(f"bank at C000 is pages {top[0]:02X} {top[1]:02X}")
    if seen != want:
        problems.append(f"ROM reads {seen[:4].hex()}, not {want[:4].hex()}")
    if locked != bool(snap.port_7ffd & 0x20):
        problems.append("the paging lock differs")
    if problems:
        raise RuntimeError("the board did not become the snapshot's 128K: " + "; ".join(problems))
    say(f"port 7FFD {snap.port_7ffd:02X}{f', 1FFD {snap.port_1ffd:02X}' if four else ''}: bank {bank} at C000, ROM {rom}, "
        f"screen {5 if not snap.port_7ffd & 8 else 7}{', locked' if locked else ''}; IM {now['IM']}")

    for number, data in enumerate(snap.banks):
        write_page(debug, number * 2, data[:0x2000])
        write_page(debug, number * 2 + 1, data[0x2000:])
    for number, data in enumerate(snap.banks):
        if read_page(debug, number * 2, 0, 0x80) != data[:0x80] or \
                read_page(debug, number * 2 + 1, 0x1F80, 0x80) != data[-0x80:]:
            raise RuntimeError(f"RAM bank {number} did not go in")
    say("eight RAM banks in")


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
    parser.add_argument("--roms", type=Path, default=os.environ.get("NEXTTANG_ROM_DIR"),
                        help="folder with the 128K or +2 ROM files, for a recording of those machines "
                             "(default: NEXTTANG_ROM_DIR)")
    parser.add_argument("--keep-divmmc", action="store_true",
                        help="leave divMMC automapping as it is")
    args = parser.parse_args(argv)

    rzx = read(args.recording)
    if not rzx.snapshots or not rzx.snapshots[0].data:
        print("the recording has no embedded snapshot", file=sys.stderr)
        return 1
    first = rzx.snapshots[0]
    snap128 = None
    ram = b""
    try:
        kind = first.extension.upper()
        if kind == "SZX":
            model = SZX_MODELS.get(first.data[6], "other") if first.data[:4] == b"ZXST" else "48"
            if model in ROM_FILES:
                snap128 = parse_szx_128(first.data)
            else:
                regs, ram = parse_szx_48k(first.data)
        elif kind == "Z80":
            if z80_model(first.data) in ROM_FILES:
                snap128 = parse_z80_128(first.data)
            else:
                regs, ram = parse_z80(first.data)
        else:
            raise ValueError(f"no reader for a .{first.extension.lower()} snapshot")
        if snap128 is not None:
            regs = snap128.regs
            if args.roms is None:
                raise ValueError(f"a {snap128.model} recording: give the folder with "
                                 f"{', '.join(ROM_FILES[snap128.model])} with --roms")
            roms = [(Path(args.roms) / name).read_bytes() for name in ROM_FILES[snap128.model]]
            if any(len(rom) != 0x4000 for rom in roms):
                raise ValueError("a ROM file is not 16K")
    except (ValueError, OSError) as error:
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
        if pages[:6] != PAGES_48K[:6] or (snap128 is None and pages != PAGES_48K):
            problem = f"not the 48K memory map: MMU {' '.join(f'{p:02X}' for p in pages)}"
        if problem:
            debug.resume()
            if nr0a & 0x10 and not args.keep_divmmc:
                debug.set_nextreg(0x0A, nr0a)
            print(problem, file=sys.stderr)
            return 1

        if snap128 is not None:
            try:
                prepare_128k(debug, memory, snap128, roms)
            except RuntimeError as error:
                print(error, file=sys.stderr)
                return 1
        else:
            try:
                run_setup(debug, memory, 0xC000, regs["IM"], [])
            except RuntimeError as error:
                print(error, file=sys.stderr)
                return 1
            if now["IM"] != regs["IM"]:
                print(f"interrupt mode set: IM {now['IM']} -> IM {regs['IM']}")
            memory.write(0x4000, ram)
        for name in ("AF", "BC", "DE", "HL", "AF'", "BC'", "DE'", "HL'", "IX", "IY", "SP", "PC", "I", "R"):
            debug.set_register(name, regs[name])
        debug.set_cpu_register(CPU_STATE_WRITE, regs["IFF2"] << 1 | regs["IFF1"])   # not halted
        check = debug.registers()
        wrong = [n for n in ("AF", "BC", "DE", "HL", "IX", "IY", "SP", "PC", "I", "IM", "IFF1", "IFF2", "HALT")
                 if check[n] != (regs[n] if n != "HALT" else 0)]
        if wrong or (snap128 is None and (memory.read(0x4000, 0x100) != ram[:0x100] or
                                          memory.read(0xFF00, 0x100) != ram[-0x100:])):
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
    restore_divmmc = bool(nr0a & 0x10) and not args.keep_divmmc and args.until is None and snap128 is None
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
    if snap128 is not None:
        print(f"the machine stays a {snap128.model} with its own ROMs (divMMC off) until it is "
              f"{'restarted' if len(roms) == 4 else 'reset'}")
    elif nr0a & 0x10 and not args.keep_divmmc and args.until is not None:
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
