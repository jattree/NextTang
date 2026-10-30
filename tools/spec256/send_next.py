#!/usr/bin/env python3
"""Load a Spec256 game's colour data into the Next core over the debug UART.

The board's Spec256 loader (rtl/input/nexttang_spec256_uart_loader.v) takes:
S1 to turn the Layer 2 mirror into the colour planes, W with the plane words
for 0x4000 to 0xFFFF, Q with the 256-entry RGB333 palette, and G with the
address of the game's first instruction, where colour mode begins. The game
itself is loaded on the Next as usual (its .SNA from the NextZXOS browser,
at 3.5 MHz); arm before loading it.

Without --palette a test palette is sent, the index's bits spread over RGB333,
enough to see whether the planes land in the right places.

Usage:
  send_next.py --gfx GAME.GFX --snapshot GAME.SNA [--palette sp256.pal] [--port DEV]
"""

from __future__ import annotations

import argparse
import os
import sys
import termios
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gfx import GFX_SIZE, decode_gfx, read_exact_file  # noqa: E402
from render import load_palette  # noqa: E402
from snapshot import parse_snapshot  # noqa: E402

PORT = "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A5069RR4-if00-port0"
BAUD_BYTES_PER_SECOND = 11_520


def plane_words(gfx: bytes) -> bytes:
    """Every Spectrum address from 0x4000, eight bytes: plane 0's first."""
    planes = decode_gfx(gfx)
    out = bytearray()
    for address in range(len(planes[0])):
        out += bytes(plane[address] for plane in planes)
    return bytes(out)


def rgb333(red: int, green: int, blue: int) -> int:
    return (red >> 5) << 6 | (green >> 5) << 3 | (blue >> 5)


def palette_bytes(path: Path | None) -> bytes:
    if path is None:
        entries = [((i >> 5) & 7) << 6 | ((i >> 2) & 7) << 3 | ((i & 3) << 1 | (i & 1))
                   for i in range(256)]
    else:
        entries = [rgb333(*colour) for colour in load_palette(path)]
    return b"".join(bytes((e & 0xFF, e >> 8)) for e in entries)


def send(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        try:
            written = os.write(fd, view)
        except BlockingIOError:
            time.sleep(0.01)
            continue
        view = view[written:]
        # Keep the kernel's queue short; the UART runs at 115200.
        time.sleep(written / BAUD_BYTES_PER_SECOND)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--gfx", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--palette", type=Path)
    parser.add_argument("--port", default=PORT)
    args = parser.parse_args()

    words = plane_words(read_exact_file(args.gfx, GFX_SIZE, "Spec256 GFX"))
    palette = palette_bytes(args.palette)
    snapshot = parse_snapshot(args.snapshot.read_bytes())
    count = len(words) // 8

    fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    started = time.time()
    send(fd, b"S1")
    send(fd, b"W4000%04x" % count + words)
    send(fd, b"Q" + palette)
    send(fd, b"G%04x" % snapshot.pc)
    time.sleep(0.2)
    os.close(fd)
    print(f"sent {count} plane words, palette ({'test' if args.palette is None else args.palette.name}), "
          f"armed at PC 0x{snapshot.pc:04x}, {time.time() - started:.0f} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
