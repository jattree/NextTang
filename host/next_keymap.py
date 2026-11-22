#!/usr/bin/env python3
r"""Load a ZX Spectrum Next keymap file into a running NextTang core.

The Next's firmware loads machines/next/keymap.bin into the core's keymap at
every boot (512 entries, two bytes each: an unused high byte, then the entry,
as NextREGs 0x2A and 0x2B take them). This tool writes such a file through the
debugger instead, so a layout can be tried without changing the SD card:

    python3 host/next_keymap.py machines/next/keymap.bin            # as the firmware would
    python3 host/next_keymap.py --uk machines/next/keymap.bin       # with the UK keyboard's two keys
    python3 host/next_keymap.py --uk --write keymapUK.bin machines/next/keymap.bin   # a file for the card

On a Next a PC key gives one Spectrum key and PC Shift adds CAPS SHIFT, so a
UK and a US keyboard differ only in two unshifted keys: the one beside Enter
(US \, UK #; set 2 code 5D) and the UK's extra key beside left Shift (\; 61).
--uk maps them to SYMBOL SHIFT + 3 (#) and SYMBOL SHIFT + D (\).

Nano 20K images with the USB keyboard through the Next's keymap (boards
97c3c2e and later) use it for the BL616's keyboard. Entry format (official
rtl/input/keymaps.vhd): bit 7 SYMBOL SHIFT, bit 6 CAPS SHIFT, bits 5-3 row,
bits 2-0 column of the Next's 8x7 matrix (7 = none); both shift bits set marks
a function key.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "host" / "debug"))

from nexttang_debug.protocol import PiDebug  # noqa: E402
from nexttang_debug.cli import DEFAULT_PORT  # noqa: E402
from nexttang_debug.uart import UartLink  # noqa: E402


UK_KEYS = {0x5D: 0x9A, 0x61: 0x8A}       # set 2 code: entry (SYMBOL SHIFT + 3, SYMBOL SHIFT + D)


def with_uk_keys(data: bytes) -> bytes:
    out = bytearray(data)
    for code, entry in UK_KEYS.items():
        out[2 * code], out[2 * code + 1] = 0, entry
    return bytes(out)


def load(debug, data: bytes) -> None:
    if len(data) != 1024:
        raise ValueError(f"a keymap file is 1024 bytes, not {len(data)}")
    debug.set_nextreg(0x28, 0x00)          # the keymap (not the key joystick), address bit 8 = 0
    debug.set_nextreg(0x29, 0x00)          # address bits 7-0 = 0
    for index in range(512):
        debug.set_nextreg(0x2A, data[2 * index])
        debug.set_nextreg(0x2B, data[2 * index + 1])   # writes the entry and moves to the next


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("keymap", type=Path)
    parser.add_argument("--uk", action="store_true", help="the UK keyboard's # and \\ keys")
    parser.add_argument("--write", type=Path, help="write the result to this file instead of the board")
    parser.add_argument("--port", default=DEFAULT_PORT)
    args = parser.parse_args()
    data = args.keymap.read_bytes()
    if len(data) != 1024:
        parser.error(f"{args.keymap}: a keymap file is 1024 bytes, not {len(data)}")
    if args.uk:
        data = with_uk_keys(data)
    if args.write:
        args.write.write_bytes(data)
        print(f"{args.write}: written")
        return 0
    with UartLink(args.port, 115200, timeout=2.0) as link:
        load(PiDebug(link), data)
    print(f"{args.keymap}: 512 entries written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
