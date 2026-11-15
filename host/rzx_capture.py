#!/usr/bin/env python3
"""Record an RZX file from a NextTang board running a 48K Spectrum program.

Needs an image built with the RZX recorder (Nano 20K: build_zxnext.sh --rzx 1)
and the debugger on the debug UART (--pi-pins 0). On the debug UART it:

1. pauses the CPU and reads its registers and the 48K of RAM at 0x4000-0xFFFF,
   which become the recording's starting snapshot (a version 1 .z80);
2. sends Z, which arms the recorder, and resumes the CPU: the recording starts
   at that instruction;
3. optionally types keys while recording (--keys, the board's K command);
4. after --seconds, sends z and reads the rest of the recording;
5. writes an RZX file holding the snapshot and the frames.

A CPU paused inside HALT is restarted at the HALT instruction (PC - 1, not
halted), so the snapshot is exactly what a Spectrum emulator will run: it
executes the HALT again, and so does the board, as both start from the same
state.

NextZXOS leaves divMMC automapping on (NextREG 0x0A bit 4), with entry points
at 0x0008 and 0x0038, so every IM 1 interrupt would briefly run NextZXOS code a
plain 48K Spectrum does not have, and an emulator's replay would go out of
step. The tool turns automapping off a second before the snapshot and puts
NextREG 0x0A back afterwards (--keep-divmmc leaves it alone).

The interrupt mode comes from the debugger's state register, which reports
the CPU's real mode only in NextTang images with the IStatus fix (2026-11-15);
the official core reports the decoder's request there, which reads as IM 2.

The border colour cannot be read back and is written as 0; it does not
affect replay. Only 48K programs are supported so far (RZX profile 1, 48K):
the tool refuses if the memory map is not the 48K one.
"""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "host/debug"))
from nexttang_debug.protocol import CMD_CPU_RESUME, PiDebug, Z80Memory  # noqa: E402
from nexttang_debug.uart import UartLink  # noqa: E402
from tools.rzx import Creator, Recording, Rzx, Snapshot, frames_from_uart, write  # noqa: E402

DEFAULT_PORT = "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A5069RR4-if00-port0"
PAGES_48K = [0xFF, 0xFF, 0x0A, 0x0B, 0x04, 0x05, 0x00, 0x01]   # ROM, banks 5, 2, 0


def z80_v1(regs: dict[str, int], ram: bytes, border: int = 0) -> bytes:
    """A version 1 .z80 (48K, uncompressed) from the debugger's registers."""
    if len(ram) != 0xC000:
        raise ValueError("48K of RAM expected")
    flags = (regs["R"] >> 7 & 1) | (border & 7) << 1
    header = struct.pack(
        "<BBHHHHBBBHHHHBBHHBBB",
        regs["AF"] >> 8, regs["AF"] & 0xFF, regs["BC"], regs["HL"], regs["PC"], regs["SP"],
        regs["I"], regs["R"] & 0x7F, flags, regs["DE"], regs["BC'"], regs["DE'"], regs["HL'"],
        regs["AF'"] >> 8, regs["AF'"] & 0xFF, regs["IY"], regs["IX"],
        regs["IFF1"], regs["IFF2"], regs["IM"] & 3)
    assert len(header) == 30
    return header + ram


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("output", type=Path, help="the .rzx to write")
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--keep-divmmc", action="store_true",
                        help="leave divMMC automapping as it is (replays elsewhere will likely desync)")
    parser.add_argument("--keys", default="",
                        help="K masks to hold while recording, as SECONDS:MASK,... (MASK 10 hex digits, "
                             "bit row*5+column; 0000000000 releases)")
    args = parser.parse_args(argv)

    plan = []
    for item in filter(None, args.keys.split(",")):
        at, mask = item.split(":")
        if len(mask) != 10:
            parser.error(f"key mask must be 10 hex digits: {mask}")
        plan.append((float(at), mask.lower()))
    plan.sort()

    with UartLink(args.port, 115200, timeout=2.0) as link:
        debug = PiDebug(link)
        nr0a = debug.nextreg(0x0A)
        if nr0a & 0x10 and not args.keep_divmmc:
            debug.set_nextreg(0x0A, nr0a & ~0x10)
            print(f"divMMC automap off (NextREG 0x0A {nr0a:02X} -> {nr0a & ~0x10:02X}) for the recording")
            time.sleep(1.0)
        debug.pause()
        memory = Z80Memory(debug)
        pages = memory.pages()
        if pages != PAGES_48K:
            debug.resume()
            print(f"not the 48K memory map: MMU {' '.join(f'{p:02X}' for p in pages)}", file=sys.stderr)
            return 1
        regs = debug.registers()
        if regs["HALT"]:
            debug.set_register("PC", (regs["PC"] - 1) & 0xFFFF)   # also leaves HALT
            regs = debug.registers()
            if memory.read(regs["PC"], 1) != b"\x76":
                print(f"halted, but no HALT at {regs['PC']:04X}", file=sys.stderr)
        ram = memory.read(0x4000, 0xC000)
        snapshot = z80_v1(regs, ram)
        print(f"snapshot: PC {regs['PC']:04X} SP {regs['SP']:04X} IM {regs['IM']} IFF1 {regs['IFF1']}")

        # Arm, then resume without waiting for the reply: from the resume on,
        # the UART carries the recording.
        fd = link.fd
        os.write(fd, b"Z")
        time.sleep(0.05)
        os.write(fd, b"X\x04" + bytes([CMD_CPU_RESUME, 0, 0, 0]))
        started = time.monotonic()
        captured = bytearray()
        stop_sent = False
        while True:
            now = time.monotonic() - started
            while plan and plan[0][0] <= now:
                os.write(fd, b"K" + plan.pop(0)[1].encode())
            if not stop_sent and now >= args.seconds:
                os.write(fd, b"z")
                stop_sent = True
                stop_time = now
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                captured += os.read(fd, 65536)
            if stop_sent:
                marker = captured.rfind(b"\xfd")
                if marker >= 0 and frames_from_uart(bytes(captured)).complete:
                    break
                if now - stop_time > 30:
                    print("no end marker within 30 s of stopping", file=sys.stderr)
                    break
        os.write(fd, b"K0000000000")
    if nr0a & 0x10 and not args.keep_divmmc:
        time.sleep(0.5)
        with UartLink(args.port, 115200, timeout=2.0) as link:
            PiDebug(link).set_nextreg(0x0A, nr0a)
        print(f"NextREG 0x0A restored to {nr0a:02X}")

    recording = frames_from_uart(bytes(captured))
    problems = []
    if not recording.complete:
        problems.append("recording incomplete")
    if recording.flags & 1:
        problems.append("a frame's fetch count saturated")
    if recording.flags & 2:
        problems.append("the recorder's FIFO overflowed: bytes were lost")
    if recording.complete and recording.frame_count != len(recording.frames):
        problems.append(f"board counted {recording.frame_count} frames, {len(recording.frames)} arrived")
    rzx = Rzx([Creator("NextTang", 0, 1), Snapshot("Z80", snapshot), Recording(0, recording.frames)])
    write(args.output, rzx)
    ins = sum(len(f.inputs) for f in recording.frames)
    print(f"{args.output}: {len(recording.frames)} frames, {ins} IN values, {len(captured)} bytes on the line")
    for problem in problems:
        print("PROBLEM:", problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
