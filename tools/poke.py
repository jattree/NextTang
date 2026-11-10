#!/usr/bin/env python3
"""Build and inspect bounded, bank-aware NextTang POKE images."""

from __future__ import annotations

import argparse
import json
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

MAGIC = b"NTPK"
VERSION = 1
HEADER = struct.Struct("<4sBBBBII")
RECORD = struct.Struct("<BBHBB")
MAX_RECORDS = 8

MACHINES = {"48k": 0, "128k": 1, "spec256": 2}
TARGETS = {"logical": 0, "bank": 1, "graphics": 2, "graphics-all": 3}


@dataclass(frozen=True)
class Poke:
    target: int
    bank: int
    address: int
    value: int


@dataclass(frozen=True)
class PokeImage:
    machine: int
    pokes: tuple[Poke, ...]


def _byte(value: object, label: str) -> int:
    parsed = int(value, 0) if isinstance(value, str) else int(value)
    if not 0 <= parsed <= 0xFF:
        raise ValueError(f"{label} must be between 0 and 255")
    return parsed


def _word(value: object, label: str) -> int:
    parsed = int(value, 0) if isinstance(value, str) else int(value)
    if not 0 <= parsed <= 0xFFFF:
        raise ValueError(f"{label} must be between 0 and 65535")
    return parsed


def validate_poke(machine: int, poke: Poke) -> None:
    if machine not in MACHINES.values():
        raise ValueError(f"unsupported machine kind: {machine}")
    if poke.target not in TARGETS.values():
        raise ValueError(f"unsupported POKE target: {poke.target}")
    if not 0 <= poke.bank <= 7:
        raise ValueError("POKE bank/lane must be between 0 and 7")
    if not 0 <= poke.value <= 0xFF or not 0 <= poke.address <= 0xFFFF:
        raise ValueError("POKE address or value is out of range")

    if poke.target == TARGETS["logical"]:
        if poke.bank != 0 or poke.address < 0x4000:
            raise ValueError("logical POKEs require bank 0 and RAM at 0x4000-0xffff")
    elif poke.target == TARGETS["bank"]:
        if machine != MACHINES["128k"] or poke.address > 0x3FFF:
            raise ValueError("physical-bank POKEs require 128K and offset 0x0000-0x3fff")
    elif poke.target in (TARGETS["graphics"], TARGETS["graphics-all"]):
        if machine != MACHINES["spec256"] or poke.address < 0x4000:
            raise ValueError("graphics POKEs require Spec256 RAM at 0x4000-0xffff")
        if poke.target == TARGETS["graphics-all"] and poke.bank != 0:
            raise ValueError("graphics-all POKEs require lane field 0")


def build_image(machine: int, pokes: Iterable[Poke]) -> bytes:
    records = tuple(pokes)
    if len(records) > MAX_RECORDS:
        raise ValueError(f"POKE image exceeds {MAX_RECORDS} records")
    for poke in records:
        validate_poke(machine, poke)
    payload = b"".join(
        RECORD.pack(p.target, p.bank, p.address, p.value, 0) for p in records
    )
    return HEADER.pack(
        MAGIC, VERSION, machine, RECORD.size, 0, len(records),
        zlib.crc32(payload) & 0xFFFFFFFF,
    ) + payload


def parse_image(image: bytes) -> PokeImage:
    if len(image) < HEADER.size:
        raise ValueError("POKE image is shorter than its header")
    magic, version, machine, record_size, reserved, count, expected_crc = (
        HEADER.unpack(image[:HEADER.size])
    )
    if magic != MAGIC or version != VERSION:
        raise ValueError("unsupported POKE image magic or version")
    if machine not in MACHINES.values() or record_size != RECORD.size or reserved:
        raise ValueError("invalid POKE image header")
    if count > MAX_RECORDS or len(image) != HEADER.size + count * RECORD.size:
        raise ValueError("invalid POKE image length or record count")
    payload = image[HEADER.size:]
    if zlib.crc32(payload) & 0xFFFFFFFF != expected_crc:
        raise ValueError("POKE image CRC mismatch")
    pokes = []
    for offset in range(0, len(payload), RECORD.size):
        target, bank, address, value, record_reserved = RECORD.unpack_from(payload, offset)
        if record_reserved:
            raise ValueError("POKE record reserved byte must be zero")
        poke = Poke(target, bank, address, value)
        validate_poke(machine, poke)
        pokes.append(poke)
    return PokeImage(machine, tuple(pokes))


def _from_json(source: Path) -> tuple[int, tuple[Poke, ...]]:
    document = json.loads(source.read_text(encoding="utf-8"))
    machine_name = document["machine"].lower()
    if machine_name not in MACHINES:
        raise ValueError(f"unsupported machine name: {machine_name}")
    pokes = []
    for item in document.get("pokes", ()):
        target_name = item.get("target", "logical").lower()
        if target_name not in TARGETS:
            raise ValueError(f"unsupported POKE target name: {target_name}")
        pokes.append(Poke(
            TARGETS[target_name], _byte(item.get("bank", 0), "bank"),
            _word(item["address"], "address"), _byte(item["value"], "value"),
        ))
    return MACHINES[machine_name], tuple(pokes)


def main() -> int:
    parser = argparse.ArgumentParser(description="build a NextTang .pok image")
    parser.add_argument("source", type=Path, help="JSON POKE description")
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    machine, pokes = _from_json(arguments.source)
    image = build_image(machine, pokes)
    arguments.output.write_bytes(image)
    print(f"{len(pokes)} POKEs -> {arguments.output} ({len(image)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
