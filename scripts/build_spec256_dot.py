#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 NextTang contributors
"""Build the .SPEC256 dot command and, given a palette, its SPEC256.RGB.

Writes OUTPUT/SPEC256 (firmware/spec256dot/spec256.asm, for C:/DOT on the
Next's SD card) and, with --palette (the 768-value text palette render.py
reads), OUTPUT/SPEC256.RGB: the 512-byte RGB333 palette the command sends,
the same bytes send_next.py sends. The palette is not part of the repository;
copy SPEC256.RGB beside the games or to C:/DOT.

Usage: build_spec256_dot.py --output DIR [--palette spec256-palette.pal]
       [--assembler sjasmplus]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE = REPO_ROOT / "firmware" / "spec256dot" / "spec256.asm"
sys.path.insert(0, str(REPO_ROOT / "tools" / "spec256"))
from send_next import palette_bytes  # noqa: E402

DOT_LIMIT = 8192


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--palette", type=Path)
    parser.add_argument("--assembler", default="sjasmplus")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    command = args.output / "SPEC256"
    subprocess.run([args.assembler, "--nologo", f"--raw={command}", str(SOURCE)], check=True)
    size = command.stat().st_size
    if size > DOT_LIMIT:
        raise SystemExit(f"SPEC256 is {size} bytes; a dot command has {DOT_LIMIT}")
    print(f"{command}: {size} bytes")
    if args.palette is not None:
        rgb = args.output / "SPEC256.RGB"
        rgb.write_bytes(palette_bytes(args.palette))
        print(f"{rgb}: 512 bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
