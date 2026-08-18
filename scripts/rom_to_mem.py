#!/usr/bin/env python3
"""Convert a binary ROM image into the hex text $readmemh expects.

Machine ROMs are not redistributable, so no ROM image and no file generated from
one belongs in this repository. The build points this at a ROM the user already
has and writes the result into the build directory.
"""

import argparse
import sys
from pathlib import Path


def convert(source: Path, destination: Path, expected_bytes: int | None) -> int:
    image = source.read_bytes()
    if expected_bytes is not None and len(image) != expected_bytes:
        print(f"rom_to_mem: {source} is {len(image)} bytes, expected {expected_bytes}",
              file=sys.stderr)
        return 1
    destination.write_text("".join(f"{byte:02x}\n" for byte in image), encoding="utf-8")
    print(f"rom_to_mem: {len(image)} bytes -> {destination}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--expect-bytes", type=int, default=None)
    arguments = parser.parse_args()

    if not arguments.source.is_file():
        print(f"rom_to_mem: no such ROM: {arguments.source}", file=sys.stderr)
        return 1
    return convert(arguments.source, arguments.destination, arguments.expect_bytes)


if __name__ == "__main__":
    sys.exit(main())
