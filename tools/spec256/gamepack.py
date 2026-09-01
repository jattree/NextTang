#!/usr/bin/env python3
"""Build a bounded runtime-loadable Spec256 game pack from private assets."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from pathlib import Path
import struct
from typing import Sequence
import zlib

from tools.spec256.gfx import GFX_SIZE, read_exact_file
from tools.spec256.hardware import (
    ROM_GFX_SIZE,
    ROM_SIZE,
    build_graphical_rom_planes,
    build_lane_memory_planes,
)
from tools.spec256.render import BACKGROUND_SIZE, load_palette
from tools.spec256.snapshot import (
    RAM_SIZE,
    SNA_SIZE,
    build_bootstrap,
    parse_snapshot,
)


MAGIC = b"NTSP256\0"
VERSION = 2
# Version 2 carries backgrounds.  The count replaces version 1's reserved byte
# rather than extending the header, so the header stays 32 bytes and the FPGA
# loader's fixed-size header read is unchanged.
HEADER = struct.Struct("<8sHHIIB4BHHHB")
HEADER_SIZE = HEADER.size
BOOT_SIZE = 16 * 1024
PLANE_COUNT = 8
PALETTE_SIZE = 256 * 3
BASE_PAYLOAD_SIZE = (
    BOOT_SIZE
    + RAM_SIZE
    + PLANE_COUNT * RAM_SIZE
    + PLANE_COUNT * (16 * 1024)
    + PALETTE_SIZE
)

# The published collection tops out at seven backgrounds, in That Sink Filling.
# Eight bounds the format without a pack existing that no hardware could accept.
MAX_BACKGROUNDS = 8


def payload_size_for(background_count: int) -> int:
    """Return the exact payload length for a background count."""
    if not 0 <= background_count <= MAX_BACKGROUNDS:
        raise ValueError(
            f"a game pack supports at most {MAX_BACKGROUNDS} backgrounds, "
            f"got {background_count}"
        )
    return BASE_PAYLOAD_SIZE + background_count * BACKGROUND_SIZE


def read_graphical_rom(path: Path) -> bytes:
    """Return the graphical ROM, ignoring any trailer the reference ignores.

    GZX's `gfxrom_load` reads exactly 16384 groups of eight bytes from the
    start of the file and never looks at the rest.  Chuckie Egg and Ruff and
    Reddy ship 134,672-byte files whose leading 131,072 bytes decode correctly
    against `zx48.rom` and whose trailing 3,600 do not, so the trailer is
    discarded rather than treated as an error.
    """
    size = path.stat().st_size
    if size < ROM_GFX_SIZE:
        raise ValueError(
            f"Spec256 ROM GFX must be at least {ROM_GFX_SIZE} bytes, got {size}"
        )
    with path.open("rb") as stream:
        payload = stream.read(ROM_GFX_SIZE)
    if len(payload) != ROM_GFX_SIZE:
        raise ValueError("Spec256 ROM GFX changed while being read")
    return payload


def default_graphical_rom_planes(rom: bytes) -> tuple[bytes, ...]:
    """Replicate the ordinary ROM into every graphical execution plane.

    GZX initializes every graphical ROM from the ordinary 48K ROM before an
    optional ROM0.GFX override.  Replication preserves executable bytes and
    makes an original set bit colour 255 while an original clear bit remains
    colour zero.  Filling every byte with 0xff instead turns all graphical ROM
    instructions and operands into 0xff.
    """
    if len(rom) != ROM_SIZE:
        raise ValueError(f"48K ROM must be exactly {ROM_SIZE} bytes, got {len(rom)}")
    return tuple(rom for _ in range(PLANE_COUNT))


SPECTRUM_KEY_INDICES = {
    "CAPS SHIFT": 0,
    "Z": 1,
    "X": 2,
    "C": 3,
    "V": 4,
    "A": 5,
    "S": 6,
    "D": 7,
    "F": 8,
    "G": 9,
    "Q": 10,
    "W": 11,
    "E": 12,
    "R": 13,
    "T": 14,
    "1": 15,
    "2": 16,
    "3": 17,
    "4": 18,
    "5": 19,
    "0": 20,
    "9": 21,
    "8": 22,
    "7": 23,
    "6": 24,
    "P": 25,
    "O": 26,
    "I": 27,
    "U": 28,
    "Y": 29,
    "ENTER": 30,
    "L": 31,
    "K": 32,
    "J": 33,
    "H": 34,
    "SPACE": 35,
    "SYMBOL SHIFT": 36,
    "M": 37,
    "N": 38,
    "B": 39,
}


@dataclass(frozen=True)
class GamePack:
    version: int
    header_size: int
    payload: bytes
    key_indices: tuple[int, ...]
    start_delay_ms: int
    hold_ms: int
    gap_ms: int
    background_count: int

    @property
    def backgrounds(self) -> tuple[bytes, ...]:
        """Return the backgrounds in index order, as the reference numbers them."""
        return tuple(
            self.payload[
                BASE_PAYLOAD_SIZE + index * BACKGROUND_SIZE :
                BASE_PAYLOAD_SIZE + (index + 1) * BACKGROUND_SIZE
            ]
            for index in range(self.background_count)
        )


def _milliseconds(value: int, description: str) -> int:
    if not 0 <= value <= 0xFFFF:
        raise ValueError(f"{description} must fit in 16 unsigned bits")
    return value


def _key_indices(keys: tuple[str, ...]) -> tuple[int, ...]:
    if len(keys) > 4:
        raise ValueError("a game pack supports at most four launch keys")
    indices = []
    for key in keys:
        canonical = key.strip().upper()
        if canonical not in SPECTRUM_KEY_INDICES:
            raise ValueError(f"unknown Spectrum key: {key}")
        indices.append(SPECTRUM_KEY_INDICES[canonical])
    return tuple(indices)


def build_gamepack(
    snapshot_source: Path,
    graphics_source: Path,
    rom_graphics_source: Path | None,
    palette_source: Path,
    *,
    rom_source: Path | None = None,
    backgrounds: Sequence[Path] = (),
    keys: tuple[str, ...] = (),
    start_delay_ms: int = 2000,
    hold_ms: int = 140,
    gap_ms: int = 4000,
) -> bytes:
    """Return one complete private game image accepted by the FPGA loader.

    When `rom_graphics_source` is None, `rom_source` supplies the ordinary ROM
    replicated into every graphical plane, matching GZX initialization.
    """
    snapshot_payload = read_exact_file(snapshot_source, SNA_SIZE, "48K SNA")
    graphics_payload = read_exact_file(graphics_source, GFX_SIZE, "Spec256 GFX")
    background_images = tuple(
        read_exact_file(source, BACKGROUND_SIZE, f"Spec256 background {index}")
        for index, source in enumerate(backgrounds)
    )
    payload_size = payload_size_for(len(background_images))
    snapshot = parse_snapshot(snapshot_payload)
    bootstrap = build_bootstrap(snapshot)
    if len(bootstrap) > BOOT_SIZE:
        raise ValueError(
            f"snapshot bootstrap exceeds {BOOT_SIZE} bytes: {len(bootstrap)}"
        )
    boot_image = bootstrap + bytes(BOOT_SIZE - len(bootstrap))
    ram_planes = build_lane_memory_planes(snapshot, graphics_payload)
    if rom_graphics_source is None:
        if rom_source is None:
            raise ValueError("a 48K ROM is required when --rom-gfx is omitted")
        rom_planes = default_graphical_rom_planes(
            read_exact_file(rom_source, ROM_SIZE, "48K ROM")
        )
    else:
        rom_planes = build_graphical_rom_planes(
            read_graphical_rom(rom_graphics_source)
        )
    palette = bytes(channel for colour in load_palette(palette_source) for channel in colour)
    payload = b"".join((
        boot_image,
        snapshot.ram,
        *ram_planes,
        *rom_planes,
        palette,
        *background_images,
    ))
    if len(payload) != payload_size:
        raise AssertionError(
            f"internal game-pack size mismatch: {len(payload)} != {payload_size}"
        )

    indices = _key_indices(keys)
    padded_keys = indices + (0,) * (4 - len(indices))
    header = HEADER.pack(
        MAGIC,
        VERSION,
        HEADER_SIZE,
        payload_size,
        zlib.crc32(payload) & 0xFFFFFFFF,
        len(indices),
        *padded_keys,
        _milliseconds(start_delay_ms, "start delay"),
        _milliseconds(hold_ms, "key hold"),
        _milliseconds(gap_ms, "key gap"),
        len(background_images),
    )
    return header + payload


def parse_gamepack(image: bytes) -> GamePack:
    """Validate and decode a complete game pack without accepting trailing data."""
    if len(image) < HEADER_SIZE:
        raise ValueError("Spec256 game pack is shorter than its header")
    fields = HEADER.unpack(image[:HEADER_SIZE])
    (
        magic,
        version,
        header_size,
        payload_size,
        expected_crc,
        key_count,
        *rest,
    ) = fields
    keys = tuple(rest[:4])
    start_delay_ms, hold_ms, gap_ms, background_count = rest[4:]
    if magic != MAGIC:
        raise ValueError("Spec256 game-pack magic does not match")
    if version != VERSION:
        raise ValueError(f"unsupported Spec256 game-pack version: {version}")
    if header_size != HEADER_SIZE:
        raise ValueError(f"unsupported Spec256 game-pack header size: {header_size}")
    if payload_size != payload_size_for(background_count):
        raise ValueError(f"unexpected Spec256 payload size: {payload_size}")
    if len(image) != HEADER_SIZE + payload_size:
        raise ValueError("Spec256 game pack is truncated or has trailing data")
    if key_count > 4:
        raise ValueError(f"invalid launch-key count: {key_count}")
    payload = image[HEADER_SIZE:]
    actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
    if actual_crc != expected_crc:
        raise ValueError(
            f"Spec256 game-pack CRC mismatch: {actual_crc:08x} != {expected_crc:08x}"
        )
    return GamePack(
        version=version,
        header_size=header_size,
        payload=payload,
        key_indices=keys[:key_count],
        start_delay_ms=start_delay_ms,
        hold_ms=hold_ms,
        gap_ms=gap_ms,
        background_count=background_count,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="build a private runtime-loadable Spec256 game pack"
    )
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--gfx", required=True, type=Path)
    parser.add_argument("--rom-gfx", type=Path,
                        help="optional; ordinary ROM colours are used without it")
    parser.add_argument("--rom", type=Path,
                        help="required when --rom-gfx is omitted")
    parser.add_argument("--background", action="append", default=[], type=Path,
                        help="repeatable, in b00-upward index order")
    parser.add_argument("--palette", required=True, type=Path)
    parser.add_argument("--key", action="append", default=[])
    parser.add_argument("--start-delay-ms", type=int, default=2000)
    parser.add_argument("--hold-ms", type=int, default=140)
    parser.add_argument("--gap-ms", type=int, default=4000)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    try:
        image = build_gamepack(
            arguments.snapshot,
            arguments.gfx,
            arguments.rom_gfx,
            arguments.palette,
            rom_source=arguments.rom,
            backgrounds=tuple(arguments.background),
            keys=tuple(arguments.key),
            start_delay_ms=arguments.start_delay_ms,
            hold_ms=arguments.hold_ms,
            gap_ms=arguments.gap_ms,
        )
        arguments.output.write_bytes(image)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(
        f"spec256_gamepack: {len(image)} bytes, "
        f"sha256={hashlib.sha256(image).hexdigest()} -> {arguments.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
