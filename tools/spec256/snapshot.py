#!/usr/bin/env python3
"""Convert a user-supplied 48K SNA into hardware build inputs."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from pathlib import Path


SNA_HEADER_SIZE = 27
RAM_BASE = 0x4000
RAM_SIZE = 48 * 1024
SNA_SIZE = SNA_HEADER_SIZE + RAM_SIZE
BOOT_STACK = RAM_BASE + 2


@dataclass(frozen=True)
class Snapshot48:
    ram: bytes
    i: int
    hl_alt: int
    de_alt: int
    bc_alt: int
    af_alt: int
    hl: int
    de: int
    bc: int
    iy: int
    ix: int
    iff2: bool
    r: int
    af: int
    sp: int
    pc: int
    im: int
    border: int


def _word(payload: bytes, offset: int) -> int:
    return int.from_bytes(payload[offset : offset + 2], "little")


def parse_snapshot(payload: bytes) -> Snapshot48:
    """Parse the fixed-size 48K SNA form and recover its stacked PC."""
    if len(payload) != SNA_SIZE:
        raise ValueError(
            f"48K SNA must be exactly {SNA_SIZE} bytes, got {len(payload)}"
        )

    header = payload[:SNA_HEADER_SIZE]
    ram = payload[SNA_HEADER_SIZE:]
    sp = _word(header, 23)
    if sp < RAM_BASE or sp > 0xFFFE:
        raise ValueError(
            f"48K SNA stack pointer 0x{sp:04x} is outside readable RAM"
        )
    pc = _word(ram, sp - RAM_BASE)
    im = header[25]
    if im > 2:
        raise ValueError(f"48K SNA interrupt mode must be 0, 1 or 2, got {im}")

    return Snapshot48(
        ram=ram,
        i=header[0],
        hl_alt=_word(header, 1),
        de_alt=_word(header, 3),
        bc_alt=_word(header, 5),
        af_alt=_word(header, 7),
        hl=_word(header, 9),
        de=_word(header, 11),
        bc=_word(header, 13),
        iy=_word(header, 15),
        ix=_word(header, 17),
        iff2=bool(header[19] & 0x04),
        r=header[20],
        af=_word(header, 21),
        sp=sp,
        pc=pc,
        im=im,
        border=header[26] & 0x07,
    )


def _ld16(opcode: int, value: int) -> bytes:
    return bytes((opcode, value & 0xFF, value >> 8))


def _load_af(value: int) -> bytes:
    # Z80 has no immediate AF load. Use BC as a temporary stack pair, then
    # restore the real BC afterwards.
    return _ld16(0x01, value) + bytes((0xC5, 0xF1))


def build_bootstrap(snapshot: Snapshot48) -> bytes:
    """Return reset code that restores the SNA state and RETs to its PC.

    The bootstrap briefly uses 0x4000-0x4001 as a stack, then restores those
    bytes before resuming. The saved SNA stack remains untouched, so the final
    RET recovers PC exactly as the 48K SNA format specifies.
    """
    program = bytearray((0xF3,))  # DI while state is being restored
    program += _ld16(0x31, BOOT_STACK)

    program += bytes((0xDD,)) + _ld16(0x21, snapshot.ix)
    program += bytes((0xFD,)) + _ld16(0x21, snapshot.iy)
    program += bytes((0x3E, snapshot.i, 0xED, 0x47))  # LD A,I; LD I,A
    program += bytes((0x3E, snapshot.border, 0xD3, 0xFE))
    program += {
        0: bytes((0xED, 0x46)),
        1: bytes((0xED, 0x56)),
        2: bytes((0xED, 0x5E)),
    }[snapshot.im]

    program += _load_af(snapshot.af_alt)
    program += _ld16(0x01, snapshot.bc_alt)
    program += _ld16(0x11, snapshot.de_alt)
    program += _ld16(0x21, snapshot.hl_alt)
    program += bytes((0xD9, 0x08))  # EXX; EX AF,AF'

    # LD R,A is deliberately late. Thirteen subsequent opcode fetches occur
    # before the resumed program's first fetch, so compensate in the low seven
    # bits while retaining R's separately stored high bit.
    adjusted_r = (snapshot.r & 0x80) | ((snapshot.r - 13) & 0x7F)
    program += bytes((0x3E, adjusted_r, 0xED, 0x4F))
    program += _load_af(snapshot.af)
    program += _ld16(0x01, snapshot.bc)
    program += _ld16(0x11, snapshot.de)

    program += _ld16(0x21, RAM_BASE)
    program += bytes((0x36, snapshot.ram[0], 0x23, 0x36, snapshot.ram[1]))
    program += _ld16(0x21, snapshot.hl)
    program += _ld16(0x31, snapshot.sp)
    program += bytes((0xFB if snapshot.iff2 else 0xF3, 0xC9))
    return bytes(program)


def build_ram_image(snapshot: Snapshot48) -> bytes:
    """Return a 64K address-aligned RAM image for the existing block RAM."""
    return bytes(RAM_BASE) + snapshot.ram


def _write_mem(path: Path, payload: bytes) -> None:
    path.write_text(
        "".join(f"{byte:02x}\n" for byte in payload),
        encoding="utf-8",
    )


def convert_snapshot(
    source: Path,
    ram_destination: Path,
    boot_destination: Path,
    manifest_destination: Path,
) -> Snapshot48:
    """Convert one private SNA without copying it into the repository."""
    payload = source.read_bytes()
    snapshot = parse_snapshot(payload)
    bootstrap = build_bootstrap(snapshot)
    _write_mem(ram_destination, build_ram_image(snapshot))
    _write_mem(boot_destination, bootstrap)
    digest = hashlib.sha256(payload).hexdigest()
    manifest_destination.write_text(
        f"{digest}  {source.name}\n"
        f"pc=0x{snapshot.pc:04x}\n"
        f"sp=0x{snapshot.sp:04x}\n",
        encoding="utf-8",
    )
    return snapshot


def main() -> int:
    parser = argparse.ArgumentParser(
        description="convert a private 48K SNA into RAM and reset-bootstrap images"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("ram_destination", type=Path)
    parser.add_argument("boot_destination", type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    arguments = parser.parse_args()

    try:
        snapshot = convert_snapshot(
            arguments.source,
            arguments.ram_destination,
            arguments.boot_destination,
            arguments.manifest,
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(
        "sna_to_mem: "
        f"PC=0x{snapshot.pc:04x} SP=0x{snapshot.sp:04x} -> "
        f"{arguments.ram_destination}, {arguments.boot_destination}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
