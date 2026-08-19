#!/usr/bin/env python3
"""Validate a small TZX subset and write byte-per-line hexadecimal memory."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import struct
import sys
import zipfile


SIGNATURE = b"ZXTape!\x1a"
SUPPORTED_BLOCKS = {0x10, 0x11, 0x30}


class TzxError(ValueError):
    """The supplied tape cannot be represented by the first tape target."""


def read_tape(path: Path) -> tuple[bytes, str]:
    """Read a raw TZX or the sole TZX member of a ZIP archive."""

    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            members = [
                item
                for item in archive.infolist()
                if not item.is_dir() and item.filename.lower().endswith(".tzx")
            ]
            if len(members) != 1:
                raise TzxError(
                    "ZIP input must contain exactly one .tzx member; "
                    f"found {len(members)}"
                )
            member = members[0]
            return archive.read(member), member.filename

    return path.read_bytes(), path.name


def require_bytes(data: bytes, offset: int, count: int, context: str) -> None:
    if offset + count > len(data):
        raise TzxError(f"truncated {context} at byte {offset}")


def validate_tzx(data: bytes, maximum_bytes: int) -> list[int]:
    """Return block IDs after validating the supported bounded subset."""

    if len(data) >= maximum_bytes:
        raise TzxError(
            f"TZX is {len(data)} bytes; this target reserves one of its "
            f"{maximum_bytes} bytes for an end marker"
        )
    require_bytes(data, 0, 10, "TZX header")
    if data[:8] != SIGNATURE:
        raise TzxError("input does not start with the TZX signature")
    if data[8] != 1:
        raise TzxError(f"unsupported TZX major version {data[8]}")

    offset = 10
    block_ids: list[int] = []
    while offset < len(data):
        block_id = data[offset]
        block_ids.append(block_id)
        offset += 1
        if block_id not in SUPPORTED_BLOCKS:
            raise TzxError(
                f"unsupported TZX block 0x{block_id:02x} at byte {offset - 1}"
            )

        if block_id == 0x30:
            require_bytes(data, offset, 1, "text block length")
            length = data[offset]
            offset += 1
            require_bytes(data, offset, length, "text block")
            offset += length
            continue

        if block_id == 0x10:
            require_bytes(data, offset, 4, "standard-speed block header")
            length = struct.unpack_from("<H", data, offset + 2)[0]
            if length == 0:
                raise TzxError("standard-speed block has no data")
            offset += 4
            require_bytes(data, offset, length, "standard-speed block data")
            offset += length
            continue

        require_bytes(data, offset, 18, "turbo-speed block header")
        pulse_lengths = struct.unpack_from("<5H", data, offset)
        pilot_pulses = struct.unpack_from("<H", data, offset + 10)[0]
        used_bits = data[offset + 12]
        length = int.from_bytes(data[offset + 15 : offset + 18], "little")
        if any(value == 0 for value in pulse_lengths):
            raise TzxError("turbo-speed block contains a zero pulse length")
        if pilot_pulses == 0:
            raise TzxError("turbo-speed block has no pilot pulses")
        if not 1 <= used_bits <= 8:
            raise TzxError(
                f"turbo-speed block has invalid final-byte bit count {used_bits}"
            )
        if length == 0:
            raise TzxError("turbo-speed block has no data")
        offset += 18
        require_bytes(data, offset, length, "turbo-speed block data")
        offset += length

    if not block_ids:
        raise TzxError("TZX contains no blocks")
    return block_ids


def write_outputs(
    data: bytes,
    source_path: Path,
    member_name: str,
    block_ids: list[int],
    output_path: Path,
    manifest_path: Path,
) -> None:
    # Block ID zero is not a TZX block. It is an internal end marker consumed
    # only after the validated input has ended, so the hardware does not need
    # a generated parameter containing the copyrighted input's exact length.
    output_path.write_text(
        "".join(f"{value:02x}\n" for value in data + b"\x00"),
        encoding="ascii",
    )
    source_digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
    tape_digest = hashlib.sha256(data).hexdigest()
    block_text = ",".join(f"0x{block_id:02x}" for block_id in block_ids)
    manifest_path.write_text(
        f"source_sha256={source_digest}\n"
        f"member={member_name}\n"
        f"tzx_sha256={tape_digest}\n"
        f"tzx_bytes={len(data)}\n"
        f"blocks={block_text}\n",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--max-bytes", type=int, default=65536)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.max_bytes <= 0:
        print("tzx_to_mem: --max-bytes must be positive", file=sys.stderr)
        return 2
    try:
        data, member_name = read_tape(args.input)
        block_ids = validate_tzx(data, args.max_bytes)
        write_outputs(
            data,
            args.input,
            member_name,
            block_ids,
            args.output,
            args.manifest,
        )
    except (OSError, TzxError, zipfile.BadZipFile) as error:
        print(f"tzx_to_mem: {error}", file=sys.stderr)
        return 1

    print(
        f"tzx_to_mem: {len(data)} bytes, {len(block_ids)} blocks -> "
        f"{args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
