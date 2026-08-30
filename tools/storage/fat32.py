#!/usr/bin/env python3
"""Small read-only FAT32/LFN reference used by the NextTang loader tests."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import struct
from typing import BinaryIO, Iterator


@dataclass(frozen=True)
class DirectoryEntry:
    name: str
    short_name: str
    attributes: int
    cluster: int
    size: int

    @property
    def is_directory(self) -> bool:
        return bool(self.attributes & 0x10)


class Fat32Error(ValueError):
    pass


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _short_checksum(raw_name: bytes) -> int:
    value = 0
    for byte in raw_name:
        value = (((value & 1) << 7) | (value >> 1)) + byte
        value &= 0xFF
    return value


class Fat32Volume:
    """Read FAT32 sectors, cluster chains, VFAT directories and files."""

    def __init__(self, stream: BinaryIO):
        self.stream = stream
        sector0 = self._read_at(0, 512)
        if sector0[510:512] != b"\x55\xaa":
            raise Fat32Error("sector zero has no 0x55AA signature")
        if _u16(sector0, 11) == 512 and sector0[13]:
            self.partition_lba = 0
            boot = sector0
        else:
            partition_type = sector0[450]
            if partition_type not in (0x0B, 0x0C):
                raise Fat32Error(f"first partition is not FAT32: 0x{partition_type:02x}")
            self.partition_lba = _u32(sector0, 454)
            boot = self.read_sector(self.partition_lba)
            if boot[510:512] != b"\x55\xaa":
                raise Fat32Error("FAT32 boot sector has no 0x55AA signature")

        if _u16(boot, 11) != 512:
            raise Fat32Error("only 512-byte FAT sectors are supported")
        self.sectors_per_cluster = boot[13]
        self.reserved_sectors = _u16(boot, 14)
        self.fat_count = boot[16]
        self.fat_sectors = _u32(boot, 36)
        self.root_cluster = _u32(boot, 44)
        if not (self.sectors_per_cluster and self.reserved_sectors and
                self.fat_count and self.fat_sectors and self.root_cluster >= 2):
            raise Fat32Error("invalid FAT32 BPB geometry")
        self.fat_lba = self.partition_lba + self.reserved_sectors
        self.data_lba = self.fat_lba + self.fat_count * self.fat_sectors

    @classmethod
    def open(cls, path: str | Path) -> "Fat32Volume":
        return cls(Path(path).open("rb"))

    def close(self) -> None:
        self.stream.close()

    def __enter__(self) -> "Fat32Volume":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _read_at(self, offset: int, size: int) -> bytes:
        self.stream.seek(offset)
        data = self.stream.read(size)
        if len(data) != size:
            raise Fat32Error(f"short read at byte {offset}: {len(data)}/{size}")
        return data

    def read_sector(self, lba: int) -> bytes:
        return self._read_at(lba * 512, 512)

    def cluster_lba(self, cluster: int) -> int:
        if cluster < 2:
            raise Fat32Error(f"invalid data cluster {cluster}")
        return self.data_lba + (cluster - 2) * self.sectors_per_cluster

    def next_cluster(self, cluster: int) -> int | None:
        offset = cluster * 4
        sector = self.read_sector(self.fat_lba + offset // 512)
        value = _u32(sector, offset % 512) & 0x0FFFFFFF
        if value >= 0x0FFFFFF8:
            return None
        if value < 2 or value == 0x0FFFFFF7:
            raise Fat32Error(f"invalid FAT link 0x{value:08x} after {cluster}")
        return value

    def cluster_chain(self, first: int) -> Iterator[int]:
        cluster = first
        visited: set[int] = set()
        while True:
            if cluster in visited:
                raise Fat32Error(f"FAT loop at cluster {cluster}")
            visited.add(cluster)
            yield cluster
            following = self.next_cluster(cluster)
            if following is None:
                return
            cluster = following

    def _cluster_bytes(self, first: int) -> Iterator[bytes]:
        for cluster in self.cluster_chain(first):
            lba = self.cluster_lba(cluster)
            for sector in range(self.sectors_per_cluster):
                yield self.read_sector(lba + sector)

    @staticmethod
    def _short_name(raw: bytes) -> str:
        base = raw[:8].decode("ascii", "replace").rstrip(" ")
        extension = raw[8:11].decode("ascii", "replace").rstrip(" ")
        return base + (f".{extension}" if extension else "")

    @staticmethod
    def _lfn_piece(entry: bytes) -> str:
        encoded = entry[1:11] + entry[14:26] + entry[28:32]
        units = struct.unpack("<13H", encoded)
        characters: list[str] = []
        for unit in units:
            if unit == 0:
                break
            if unit != 0xFFFF:
                characters.append(chr(unit))
        return "".join(characters)

    def iter_directory(self, first_cluster: int | None = None) -> Iterator[DirectoryEntry]:
        lfn_parts: dict[int, str] = {}
        lfn_checksum: int | None = None
        for sector in self._cluster_bytes(first_cluster or self.root_cluster):
            for offset in range(0, 512, 32):
                entry = sector[offset:offset + 32]
                if entry[0] == 0:
                    return
                if entry[0] == 0xE5:
                    lfn_parts.clear(); lfn_checksum = None
                    continue
                if entry[11] == 0x0F:
                    ordinal = entry[0] & 0x1F
                    if not ordinal:
                        lfn_parts.clear(); lfn_checksum = None
                        continue
                    if entry[0] & 0x40:
                        lfn_parts.clear()
                        lfn_checksum = entry[13]
                    if entry[13] == lfn_checksum:
                        lfn_parts[ordinal] = self._lfn_piece(entry)
                    continue
                raw_short = entry[:11]
                short_name = self._short_name(raw_short)
                valid_lfn = lfn_parts and lfn_checksum == _short_checksum(raw_short)
                name = "".join(lfn_parts[key] for key in sorted(lfn_parts)) \
                    if valid_lfn else short_name
                lfn_parts.clear(); lfn_checksum = None
                if entry[11] & 0x08:  # volume label
                    continue
                yield DirectoryEntry(
                    name=name, short_name=short_name, attributes=entry[11],
                    cluster=(_u16(entry, 20) << 16) | _u16(entry, 26),
                    size=_u32(entry, 28),
                )

    def find(self, path: str) -> DirectoryEntry:
        components = [part for part in path.replace("\\", "/").split("/") if part]
        cluster = self.root_cluster
        found: DirectoryEntry | None = None
        for index, component in enumerate(components):
            folded = component.casefold()
            found = next((entry for entry in self.iter_directory(cluster)
                          if entry.name.casefold() == folded or
                          entry.short_name.casefold() == folded), None)
            if found is None:
                raise FileNotFoundError(path)
            if index != len(components) - 1:
                if not found.is_directory:
                    raise NotADirectoryError(component)
                cluster = found.cluster
        if found is None:
            raise FileNotFoundError(path)
        return found

    def read_file(self, entry: DirectoryEntry) -> bytes:
        if entry.is_directory:
            raise IsADirectoryError(entry.name)
        remaining = entry.size
        result = bytearray()
        if not remaining:
            return b""
        for block in self._cluster_bytes(entry.cluster):
            take = min(remaining, len(block))
            result.extend(block[:take])
            remaining -= take
            if not remaining:
                return bytes(result)
        raise Fat32Error(f"cluster chain for {entry.name!r} ended {remaining} bytes early")
