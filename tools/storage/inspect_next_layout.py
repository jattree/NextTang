#!/usr/bin/env python3
"""Read-only inventory of a Next-style FAT32 card or image."""

from __future__ import annotations

import argparse
from pathlib import Path

from fat32 import Fat32Volume


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path, help="card block device or image (opened read-only)")
    args = parser.parse_args()
    with Fat32Volume.open(args.image) as volume:
        print(f"partition_lba={volume.partition_lba} root_cluster={volume.root_cluster}")
        for directory in ("games", "machines", "nextzxos", "cores", "roms"):
            try:
                entry = volume.find("/" + directory)
            except FileNotFoundError:
                print(f"/{directory}: absent")
                continue
            if not entry.is_directory:
                print(f"/{directory}: present but not a directory")
                continue
            children = list(volume.iter_directory(entry.cluster))
            print(f"/{directory}: {len(children)} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
