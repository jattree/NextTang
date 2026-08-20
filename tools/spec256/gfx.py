#!/usr/bin/env python3
"""Inspect and transpose the original 48K Spec256 GFX format.

The format stores eight colour bytes for every byte in the Spectrum's 48 KiB
RAM image. GZX transposes those groups into eight 48 KiB bit planes. This
module implements that reversible mapping without importing any game data.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from typing import Sequence


RAM_SIZE = 3 * 16_384
PLANE_COUNT = 8
GFX_SIZE = RAM_SIZE * PLANE_COUNT


def read_exact_file(path: Path, expected_size: int, description: str) -> bytes:
    """Read a fixed-size input without accepting an unbounded payload."""
    size = path.stat().st_size
    if size != expected_size:
        raise ValueError(
            f"{description} must be exactly {expected_size} bytes, got {size}"
        )

    with path.open("rb") as stream:
        payload = stream.read(expected_size + 1)
    if len(payload) != expected_size:
        raise ValueError(
            f"{description} changed while being read; expected {expected_size} bytes, "
            f"got {len(payload)}"
        )
    return payload


def decode_gfx(payload: bytes) -> tuple[bytes, ...]:
    """Return the eight 48 KiB planes encoded by a Spec256 GFX payload."""
    if len(payload) != GFX_SIZE:
        raise ValueError(
            f"Spec256 GFX must be exactly {GFX_SIZE} bytes, got {len(payload)}"
        )

    planes = [bytearray(RAM_SIZE) for _ in range(PLANE_COUNT)]
    for address in range(RAM_SIZE):
        group = payload[address * PLANE_COUNT : (address + 1) * PLANE_COUNT]
        for plane_index in range(PLANE_COUNT):
            value = 0
            for group_index, colour in enumerate(group):
                value |= ((colour >> plane_index) & 1) << group_index
            planes[plane_index][address] = value

    return tuple(bytes(plane) for plane in planes)


def encode_gfx(planes: Sequence[bytes]) -> bytes:
    """Return the interleaved GFX payload for eight 48 KiB planes."""
    if len(planes) != PLANE_COUNT:
        raise ValueError(
            f"Spec256 GFX requires {PLANE_COUNT} planes, got {len(planes)}"
        )
    for plane_index, plane in enumerate(planes):
        if len(plane) != RAM_SIZE:
            raise ValueError(
                f"plane {plane_index} must be exactly {RAM_SIZE} bytes, "
                f"got {len(plane)}"
            )

    payload = bytearray(GFX_SIZE)
    for address in range(RAM_SIZE):
        base = address * PLANE_COUNT
        for group_index in range(PLANE_COUNT):
            colour = 0
            for plane_index, plane in enumerate(planes):
                colour |= ((plane[address] >> group_index) & 1) << plane_index
            payload[base + group_index] = colour

    return bytes(payload)


def pixel_colour(
    planes: Sequence[bytes], address: int, pixel_index: int
) -> int:
    """Return the eight-bit colour for a pixel in one shadow screen byte."""
    if not 0 <= address < RAM_SIZE:
        raise ValueError(f"address must be between 0 and {RAM_SIZE - 1}")
    if not 0 <= pixel_index < 8:
        raise ValueError("pixel index must be between 0 and 7")
    if len(planes) != PLANE_COUNT or any(len(plane) != RAM_SIZE for plane in planes):
        raise ValueError("pixel lookup requires eight 48 KiB planes")

    source_bit = 7 - pixel_index
    colour = 0
    for plane_index, plane in enumerate(planes):
        colour |= ((plane[address] >> source_bit) & 1) << plane_index
    return colour


def inspect(path: Path) -> None:
    """Validate one GFX file and print stable identifiers for its planes."""
    payload = read_exact_file(path, GFX_SIZE, "Spec256 GFX")
    planes = decode_gfx(payload)
    round_trip = encode_gfx(planes)

    print(f"path: {path}")
    print(f"bytes: {len(payload)}")
    print(f"sha256: {hashlib.sha256(payload).hexdigest()}")
    for plane_index, plane in enumerate(planes):
        print(
            f"plane-{plane_index}-sha256: "
            f"{hashlib.sha256(plane).hexdigest()}"
        )
    print(f"round-trip-identical: {'yes' if round_trip == payload else 'no'}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="validate and identify an original 48K Spec256 GFX file"
    )
    parser.add_argument("gfx", type=Path, help="user-supplied 393216-byte GFX file")
    arguments = parser.parse_args()

    try:
        inspect(arguments.gfx)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
