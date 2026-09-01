#!/usr/bin/env python3
"""Generate asset-free Spec256 instruction-conformance fixtures."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.spec256.gfx import RAM_SIZE, encode_gfx


SNA_HEADER_SIZE = 27
RAM_BASE = 0x4000
PROGRAM_ADDRESS = 0x8000
SOURCE_ADDRESS = 0x9000
DESTINATION_ADDRESS = 0x4000
STACK_ADDRESS = 0xFF00

# LD A,(0x9000); LD (0x4000),A; HALT
LD_COPY_PROGRAM = bytes((0x3A, 0x00, 0x90, 0x32, 0x00, 0x40, 0x76))
SOURCE_PLANE_BYTES = tuple(0x80 >> plane for plane in range(8))
ADDRESS_PROGRAM = bytes((0x2A, 0x00, 0x90, 0x36, 0x5A, 0x76))
ADDRESS_DESTINATION = 0x5000


def ram_offset(address: int) -> int:
    """Translate a 48K Spectrum address to its SNA RAM offset."""
    if not RAM_BASE <= address <= 0xFFFF:
        raise ValueError("48K SNA RAM address must be between 0x4000 and 0xffff")
    return address - RAM_BASE


def build_ld_copy_fixture() -> tuple[bytes, bytes]:
    """Return a synthetic SNA/GFX pair for one graphical load and store."""
    ram = bytearray(RAM_SIZE)
    program_offset = ram_offset(PROGRAM_ADDRESS)
    ram[program_offset : program_offset + len(LD_COPY_PROGRAM)] = LD_COPY_PROGRAM
    ram[ram_offset(SOURCE_ADDRESS)] = 0xAA

    # A 48K SNA stores PC on the stack. GZX pops it after loading RAM.
    stack_offset = ram_offset(STACK_ADDRESS)
    ram[stack_offset : stack_offset + 2] = PROGRAM_ADDRESS.to_bytes(2, "little")

    header = bytearray(SNA_HEADER_SIZE)
    header[23:25] = STACK_ADDRESS.to_bytes(2, "little")
    header[25] = 1
    snapshot = bytes(header + ram)

    planes = [bytearray(ram) for _ in range(8)]
    source_offset = ram_offset(SOURCE_ADDRESS)
    for plane, source_byte in zip(planes, SOURCE_PLANE_BYTES, strict=True):
        plane[source_offset] = source_byte
    graphics = encode_gfx(tuple(bytes(plane) for plane in planes))
    return snapshot, graphics


def build_master_address_fixture() -> tuple[bytes, bytes]:
    """Return a pair that distinguishes master from per-plane addressing."""
    ram = bytearray(RAM_SIZE)
    program_offset = ram_offset(PROGRAM_ADDRESS)
    ram[program_offset : program_offset + len(ADDRESS_PROGRAM)] = ADDRESS_PROGRAM
    ram[ram_offset(SOURCE_ADDRESS) : ram_offset(SOURCE_ADDRESS) + 2] = \
        ADDRESS_DESTINATION.to_bytes(2, "little")

    stack_offset = ram_offset(STACK_ADDRESS)
    ram[stack_offset : stack_offset + 2] = PROGRAM_ADDRESS.to_bytes(2, "little")
    header = bytearray(SNA_HEADER_SIZE)
    header[23:25] = STACK_ADDRESS.to_bytes(2, "little")
    header[25] = 1

    planes = [bytearray(ram) for _ in range(8)]
    source_offset = ram_offset(SOURCE_ADDRESS)
    for lane, plane in enumerate(planes):
        plane[source_offset : source_offset + 2] = \
            (ADDRESS_DESTINATION + lane).to_bytes(2, "little")
    return bytes(header + ram), encode_gfx(tuple(bytes(plane) for plane in planes))


def expected_ld_copy_planes(graphics: bytes) -> tuple[bytes, ...]:
    """Return the expected planes after the fixture's load and store."""
    from tools.spec256.gfx import decode_gfx

    planes = [bytearray(plane) for plane in decode_gfx(graphics)]
    source_offset = ram_offset(SOURCE_ADDRESS)
    destination_offset = ram_offset(DESTINATION_ADDRESS)
    for plane in planes:
        plane[destination_offset] = plane[source_offset]
    return tuple(bytes(plane) for plane in planes)


def write_ld_copy_fixture(output_directory: Path) -> tuple[Path, Path]:
    """Write the synthetic pair and return its paths."""
    output_directory.mkdir(parents=True, exist_ok=True)
    snapshot, graphics = build_ld_copy_fixture()
    snapshot_path = output_directory / "LD_COPY.SNA"
    graphics_path = output_directory / "LD_COPY.GFX"
    with snapshot_path.open("xb") as stream:
        stream.write(snapshot)
    with graphics_path.open("xb") as stream:
        stream.write(graphics)
    return snapshot_path, graphics_path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="generate a synthetic Spec256 LD A,(nn) / LD (nn),A fixture"
    )
    parser.add_argument("output_directory", type=Path)
    arguments = parser.parse_args()

    try:
        snapshot_path, graphics_path = write_ld_copy_fixture(
            arguments.output_directory
        )
    except OSError as error:
        parser.error(str(error))

    print(snapshot_path)
    print(graphics_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
