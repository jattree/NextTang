#!/usr/bin/env python3
"""Prepare private Spec256 SNA/GFX pairs for the FPGA lane memory."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys
from typing import Sequence

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.spec256.gfx import GFX_SIZE, PLANE_COUNT, read_exact_file
from tools.spec256.snapshot import RAM_BASE, SNA_SIZE, Snapshot48, parse_snapshot
from tools.spec256.render import load_palette


ROM_SIZE = 16 * 1024
ROM_GFX_SIZE = ROM_SIZE * PLANE_COUNT


def _transpose_group(group: bytes) -> tuple[int, ...]:
    """Transpose eight palette indices into eight one-bit byte planes."""
    values = []
    for plane_index in range(PLANE_COUNT):
        value = 0
        for pixel_index, colour in enumerate(group):
            value |= ((colour >> plane_index) & 1) << pixel_index
        values.append(value)
    return tuple(values)


def apply_gfx_overrides(
    snapshot: Snapshot48, graphics: bytes
) -> tuple[bytes, ...]:
    """Transpose every Spec256 GFX group into eight graphical RAM planes.

    GZX's reference loader applies the same transpose to every eight-byte
    group. Zero and ``0xff`` values are ordinary graphical data, not markers
    for retaining the corresponding byte from the Spectrum snapshot.
    """
    if len(graphics) != GFX_SIZE:
        raise ValueError(
            f"Spec256 GFX must be exactly {GFX_SIZE} bytes, got {len(graphics)}"
        )

    planes = [bytearray(snapshot.ram) for _ in range(PLANE_COUNT)]
    for offset in range(len(snapshot.ram)):
        group = graphics[offset * PLANE_COUNT : (offset + 1) * PLANE_COUNT]
        for plane_index, value in enumerate(_transpose_group(group)):
            planes[plane_index][offset] = value
    return tuple(bytes(plane) for plane in planes)


def build_lane_memory_image(
    snapshot: Snapshot48, graphics: bytes
) -> tuple[int, ...]:
    """Return 64K 64-bit words with graphical lane zero in bits 7:0."""
    planes = apply_gfx_overrides(snapshot, graphics)
    words = [0] * (64 * 1024)
    for offset in range(len(snapshot.ram)):
        word = 0
        for lane, plane in enumerate(planes):
            word |= plane[offset] << (lane * 8)
        words[RAM_BASE + offset] = word
    return tuple(words)


def build_lane_memory_planes(
    snapshot: Snapshot48, graphics: bytes
) -> tuple[bytes, ...]:
    """Return eight independently addressed 48K graphical RAM images."""
    return apply_gfx_overrides(snapshot, graphics)


def write_lane_memory(path: Path, words: Sequence[int]) -> None:
    """Write one 64-bit hexadecimal word per FPGA memory address."""
    if any(word < 0 or word > 0xFFFFFFFFFFFFFFFF for word in words):
        raise ValueError("Spec256 lane-memory words must fit in 64 bits")
    path.write_text(
        "".join(f"{word:016x}\n" for word in words),
        encoding="ascii",
    )


def write_plane_memories(
    destination: Path, planes: Sequence[bytes]
) -> tuple[Path, ...]:
    """Write the eight byte-wide RAM images used by the graphical Z80s."""
    if len(planes) != PLANE_COUNT:
        raise ValueError(f"expected {PLANE_COUNT} Spec256 planes, got {len(planes)}")
    paths = tuple(
        destination / f"spec256-plane{lane}.mem"
        for lane in range(PLANE_COUNT)
    )
    for lane, (path, plane) in enumerate(zip(paths, planes, strict=True)):
        if len(plane) != 48 * 1024:
            raise ValueError(
                f"Spec256 plane must be exactly 49152 bytes, got {len(plane)}"
            )
        path.write_text(
            "".join(f"{byte:02x}\n" for byte in plane),
            encoding="ascii",
        )
        for bank in range(3):
            bank_payload = plane[bank * 16 * 1024 : (bank + 1) * 16 * 1024]
            (destination / f"spec256-plane{lane}-bank{bank}.mem").write_text(
                "".join(f"{byte:02x}\n" for byte in bank_payload),
                encoding="ascii",
            )
    return paths


def build_graphical_rom_planes(graphics: bytes) -> tuple[bytes, ...]:
    """Transpose the complete Spec256 graphical ROM into eight byte lanes."""
    if len(graphics) != ROM_GFX_SIZE:
        raise ValueError(
            f"Spec256 ROM GFX must be exactly {ROM_GFX_SIZE} bytes, "
            f"got {len(graphics)}"
        )
    planes = [bytearray(ROM_SIZE) for _ in range(PLANE_COUNT)]
    for address in range(ROM_SIZE):
        group = graphics[address * PLANE_COUNT : (address + 1) * PLANE_COUNT]
        for lane, value in enumerate(_transpose_group(group)):
            planes[lane][address] = value
    return tuple(bytes(plane) for plane in planes)


def write_graphical_rom_memories(
    destination: Path, planes: Sequence[bytes]
) -> tuple[Path, ...]:
    """Write the eight independently addressed graphical ROM images."""
    expected_size = ROM_SIZE
    if len(planes) != PLANE_COUNT:
        raise ValueError(f"expected {PLANE_COUNT} Spec256 ROM planes, got {len(planes)}")
    paths = tuple(
        destination / f"spec256-rom-plane{lane}.mem"
        for lane in range(PLANE_COUNT)
    )
    for path, plane in zip(paths, planes, strict=True):
        if len(plane) != expected_size:
            raise ValueError(
                f"Spec256 ROM must be exactly {expected_size} bytes, "
                f"got {len(plane)}"
            )
        path.write_text(
            "".join(f"{byte:02x}\n" for byte in plane),
            encoding="ascii",
        )
    return paths


def write_palette_memory(source: Path, destination: Path) -> None:
    """Convert the standard Spec256 text palette to 24-bit FPGA words."""
    palette = load_palette(source)
    destination.write_text(
        "".join(f"{red:02x}{green:02x}{blue:02x}\n" for red, green, blue in palette),
        encoding="ascii",
    )


def convert_hardware_image(
    snapshot_source: Path,
    graphics_source: Path,
    rom_graphics_source: Path,
    destination: Path,
    manifest_destination: Path,
) -> Snapshot48:
    """Convert one private SNA/GFX pair without importing either asset."""
    snapshot_payload = read_exact_file(snapshot_source, SNA_SIZE, "48K SNA")
    graphics_payload = read_exact_file(graphics_source, GFX_SIZE, "Spec256 GFX")
    rom_graphics_payload = read_exact_file(
        rom_graphics_source, ROM_GFX_SIZE, "Spec256 ROM GFX"
    )
    snapshot = parse_snapshot(snapshot_payload)
    write_lane_memory(
        destination,
        build_lane_memory_image(snapshot, graphics_payload),
    )
    write_plane_memories(
        destination.parent,
        build_lane_memory_planes(snapshot, graphics_payload),
    )
    (destination.parent / "spec256-main.mem").write_text(
        "".join(f"{byte:02x}\n" for byte in snapshot.ram),
        encoding="ascii",
    )
    for bank in range(3):
        bank_payload = snapshot.ram[bank * 16 * 1024 : (bank + 1) * 16 * 1024]
        (destination.parent / f"spec256-main-bank{bank}.mem").write_text(
            "".join(f"{byte:02x}\n" for byte in bank_payload),
            encoding="ascii",
        )
    write_graphical_rom_memories(
        destination.parent,
        build_graphical_rom_planes(rom_graphics_payload),
    )
    manifest_destination.write_text(
        f"{hashlib.sha256(snapshot_payload).hexdigest()}  {snapshot_source.name}\n"
        f"{hashlib.sha256(graphics_payload).hexdigest()}  {graphics_source.name}\n"
        f"{hashlib.sha256(rom_graphics_payload).hexdigest()}  "
        f"{rom_graphics_source.name}\n"
        f"pc=0x{snapshot.pc:04x}\n"
        f"sp=0x{snapshot.sp:04x}\n",
        encoding="ascii",
    )
    return snapshot


def main() -> int:
    parser = argparse.ArgumentParser(
        description="convert a private Spec256 SNA/GFX pair into FPGA lane RAM"
    )
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("graphics", type=Path)
    parser.add_argument("--rom-gfx", required=True, type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--palette-source", required=True, type=Path)
    parser.add_argument("--palette-destination", required=True, type=Path)
    arguments = parser.parse_args()

    try:
        snapshot = convert_hardware_image(
            arguments.snapshot,
            arguments.graphics,
            arguments.rom_gfx,
            arguments.destination,
            arguments.manifest,
        )
        write_palette_memory(
            arguments.palette_source,
            arguments.palette_destination,
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(
        "spec256_to_mem: "
        f"PC=0x{snapshot.pc:04x} SP=0x{snapshot.sp:04x} -> "
        f"{arguments.destination}, {arguments.palette_destination}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
