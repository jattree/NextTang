#!/usr/bin/env python3
"""Read, write and inspect RZX input recordings (format revision 0.13).

The host half of the planned replay work (docs/replay-and-rewind.md): it turns a
snapshot plus a per-frame log of fetch counts and IN values into an .rzx file and
back, so recordings made on the board can be checked against emulators and RZX
Archive recordings can be fed to the board's player.

Written from Ramsoft's published RZX specification, revision 0.13 (2 March
2005). The container is little-endian: a 10-byte header ("RZX!", major 0, minor
13, flags), then blocks of ID (1 byte) + length (4 bytes, whole block). Block
0x10 names the creator, 0x30 carries a snapshot, 0x80 carries frames. A frame is
the fetch count up to the interrupt (R-register increments: 1 per opcode fetch,
2 for a prefixed instruction, the interrupt acknowledge not counted), the number
of IN reads (65535: the same reads as the previous frame) and the read values.

Security blocks (0x20/0x21, marked obsolete in the specification) and any
unknown block are kept as raw bytes and written back unchanged; encrypted
(protected) recordings are refused.
"""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Union

SIGNATURE = b"RZX!"
MAJOR, MINOR = 0, 13
HEADER = struct.Struct("<4sBBI")
BLOCK_HEAD = struct.Struct("<BI")
CREATOR = struct.Struct("<20sHH")
SNAPSHOT = struct.Struct("<I4sI")
RECORDING = struct.Struct("<IBII")
FRAME_HEAD = struct.Struct("<HH")

CREATOR_ID, SECURITY_INFO_ID, SECURITY_SIG_ID = 0x10, 0x20, 0x21
SNAPSHOT_ID, RECORDING_ID = 0x30, 0x80
REPEAT = 0xFFFF
SNAP_EXTERNAL, SNAP_COMPRESSED = 1, 2
REC_PROTECTED, REC_COMPRESSED = 1, 2
FILE_SIGNED = 1


class RzxError(ValueError):
    """A malformed or unsupported RZX file."""


@dataclass
class Creator:
    name: str = "NextTang"
    major: int = 0
    minor: int = 1
    custom: bytes = b""


@dataclass
class Snapshot:
    extension: str  # "Z80", "SZX", "SNA", ...
    data: bytes = b""  # the image, or empty when external
    external_name: str | None = None  # set for a snapshot descriptor
    external_checksum: int = 0
    compress: bool = True


@dataclass
class Frame:
    fetches: int
    inputs: bytes  # every IN value of the frame, repeats already resolved


@dataclass
class Recording:
    tstates: int = 0  # T-state counter at the start of the block
    frames: list[Frame] = field(default_factory=list)
    compress: bool = True


@dataclass
class RawBlock:
    block_id: int
    payload: bytes  # everything after the 5-byte block head


Block = Union[Creator, Snapshot, Recording, RawBlock]


@dataclass
class Rzx:
    blocks: list[Block] = field(default_factory=list)
    flags: int = 0
    major: int = MAJOR
    minor: int = MINOR

    @property
    def recordings(self) -> list[Recording]:
        return [b for b in self.blocks if isinstance(b, Recording)]

    @property
    def snapshots(self) -> list[Snapshot]:
        return [b for b in self.blocks if isinstance(b, Snapshot)]

    def frames(self) -> list[Frame]:
        return [f for r in self.recordings for f in r.frames]


def _asciiz(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("ascii", "replace")


def _inflate(data: bytes, expected: int | None, what: str) -> bytes:
    try:
        out = zlib.decompress(data)
    except zlib.error as error:
        raise RzxError(f"{what}: bad zlib data ({error})") from None
    if expected is not None and len(out) != expected:
        raise RzxError(f"{what}: inflated to {len(out)} bytes, header says {expected}")
    return out


def _parse_frames(data: bytes, count: int) -> list[Frame]:
    frames: list[Frame] = []
    pos, previous = 0, b""
    for index in range(count):
        if pos + FRAME_HEAD.size > len(data):
            raise RzxError(f"frame {index}: truncated header")
        fetches, reads = FRAME_HEAD.unpack_from(data, pos)
        pos += FRAME_HEAD.size
        if reads == REPEAT:
            inputs = previous
        else:
            if pos + reads > len(data):
                raise RzxError(f"frame {index}: {reads} IN values, data truncated")
            inputs = data[pos:pos + reads]
            pos += reads
        frames.append(Frame(fetches, inputs))
        previous = inputs
    if pos != len(data):
        raise RzxError(f"{len(data) - pos} bytes after the last of {count} frames")
    return frames


def _pack_frames(frames: list[Frame]) -> bytes:
    out = bytearray()
    previous: bytes | None = None
    for index, frame in enumerate(frames):
        if not 0 <= frame.fetches <= 0xFFFF:
            raise RzxError(f"frame {index}: fetch count {frame.fetches} does not fit a WORD")
        if previous is not None and frame.inputs == previous:
            out += FRAME_HEAD.pack(frame.fetches, REPEAT)
        else:
            if len(frame.inputs) >= REPEAT:
                raise RzxError(f"frame {index}: {len(frame.inputs)} IN values (at most 65534)")
            out += FRAME_HEAD.pack(frame.fetches, len(frame.inputs)) + frame.inputs
        previous = frame.inputs
    return bytes(out)


def parse(data: bytes) -> Rzx:
    if len(data) < HEADER.size:
        raise RzxError("shorter than the RZX header")
    signature, major, minor, flags = HEADER.unpack_from(data)
    if signature != SIGNATURE:
        raise RzxError("not an RZX file (no RZX! signature)")
    rzx = Rzx(flags=flags, major=major, minor=minor)
    pos = HEADER.size
    while pos < len(data):
        if pos + BLOCK_HEAD.size > len(data):
            raise RzxError(f"block head at {pos:#x} truncated")
        block_id, length = BLOCK_HEAD.unpack_from(data, pos)
        if length < BLOCK_HEAD.size or pos + length > len(data):
            raise RzxError(f"block {block_id:#04x} at {pos:#x}: bad length {length}")
        payload = data[pos + BLOCK_HEAD.size:pos + length]
        rzx.blocks.append(_parse_block(block_id, payload, pos))
        pos += length
    return rzx


def _parse_block(block_id: int, payload: bytes, pos: int) -> Block:
    where = f"block {block_id:#04x} at {pos:#x}"
    if block_id == CREATOR_ID:
        if len(payload) < CREATOR.size:
            raise RzxError(f"{where}: creator block too short")
        name, major, minor = CREATOR.unpack_from(payload)
        return Creator(_asciiz(name), major, minor, payload[CREATOR.size:])
    if block_id == SNAPSHOT_ID:
        if len(payload) < SNAPSHOT.size:
            raise RzxError(f"{where}: snapshot block too short")
        flags, extension, length = SNAPSHOT.unpack_from(payload)
        body = payload[SNAPSHOT.size:]
        compressed = bool(flags & SNAP_COMPRESSED)
        if flags & SNAP_EXTERNAL:
            # The descriptor itself may be compressed too; its length field is
            # the inflated size like any other payload.
            body = _inflate(body, length, where) if compressed else body
            if len(body) < 4:
                raise RzxError(f"{where}: snapshot descriptor too short")
            (checksum,) = struct.unpack_from("<I", body)
            return Snapshot(_asciiz(extension), b"", _asciiz(body[4:]), checksum, compressed)
        if compressed:
            body = _inflate(body, length, where)
        elif len(body) != length:
            raise RzxError(f"{where}: {len(body)} snapshot bytes, header says {length}")
        return Snapshot(_asciiz(extension), body, compress=compressed)
    if block_id == RECORDING_ID:
        if len(payload) < RECORDING.size:
            raise RzxError(f"{where}: recording block too short")
        count, _reserved, tstates, flags = RECORDING.unpack_from(payload)
        if flags & REC_PROTECTED:
            raise RzxError(f"{where}: protected (encrypted) recording, not supported")
        body = payload[RECORDING.size:]
        compressed = bool(flags & REC_COMPRESSED)
        if compressed:
            body = _inflate(body, None, where)
        return Recording(tstates, _parse_frames(body, count), compressed)
    return RawBlock(block_id, payload)


def serialise(rzx: Rzx) -> bytes:
    out = bytearray(HEADER.pack(SIGNATURE, rzx.major, rzx.minor, rzx.flags))
    for block in rzx.blocks:
        block_id, payload = _pack_block(block)
        out += BLOCK_HEAD.pack(block_id, BLOCK_HEAD.size + len(payload)) + payload
    return bytes(out)


def _pack_block(block: Block) -> tuple[int, bytes]:
    if isinstance(block, Creator):
        name = block.name.encode("ascii")
        if len(name) > 19:
            raise RzxError("creator name longer than 19 characters")
        return CREATOR_ID, CREATOR.pack(name, block.major, block.minor) + block.custom
    if isinstance(block, Snapshot):
        extension = block.extension.encode("ascii")
        if len(extension) > 3:
            raise RzxError("snapshot extension longer than 3 characters")
        if block.external_name is not None:
            body = struct.pack("<I", block.external_checksum) + block.external_name.encode("ascii") + b"\0"
            flags = SNAP_EXTERNAL
        else:
            body, flags = block.data, 0
        length = len(body)
        if block.compress:
            body, flags = zlib.compress(body, 9), flags | SNAP_COMPRESSED
        return SNAPSHOT_ID, SNAPSHOT.pack(flags, extension, length) + body
    if isinstance(block, Recording):
        body, flags = _pack_frames(block.frames), 0
        if block.compress:
            body, flags = zlib.compress(body, 9), REC_COMPRESSED
        return RECORDING_ID, RECORDING.pack(len(block.frames), 0, block.tstates, flags) + body
    return block.block_id, block.payload


def read(path: Path) -> Rzx:
    return parse(path.read_bytes())


def write(path: Path, rzx: Rzx) -> None:
    path.write_bytes(serialise(rzx))


def describe(rzx: Rzx) -> str:
    lines = [f"RZX {rzx.major}.{rzx.minor}, flags {rzx.flags:#x}"
             + (" (signed)" if rzx.flags & FILE_SIGNED else "")]
    first = 0
    for block in rzx.blocks:
        if isinstance(block, Creator):
            lines.append(f"creator: {block.name} {block.major}.{block.minor}"
                         + (f", {len(block.custom)} bytes custom" if block.custom else ""))
        elif isinstance(block, Snapshot):
            if block.external_name is not None:
                lines.append(f"snapshot: external {block.extension} '{block.external_name}'"
                             f" checksum {block.external_checksum:#010x}")
            else:
                lines.append(f"snapshot: {block.extension}, {len(block.data)} bytes"
                             + (" (compressed)" if block.compress else ""))
        elif isinstance(block, Recording):
            frames = block.frames
            reads = sum(len(f.inputs) for f in frames)
            fetches = [f.fetches for f in frames] or [0]
            lines.append(f"recording: frames {first}-{first + len(frames) - 1}, {len(frames)} frames,"
                         f" T-states {block.tstates}, {reads} IN values,"
                         f" fetches per frame {min(fetches)}-{max(fetches)}"
                         + (" (compressed)" if block.compress else ""))
            first += len(frames)
        else:
            lines.append(f"block {block.block_id:#04x}: {len(block.payload) + BLOCK_HEAD.size} bytes kept as is")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    info = sub.add_parser("info", help="list the blocks of an RZX file")
    info.add_argument("file", type=Path)
    frames = sub.add_parser("frames", help="print frames: index, fetch count, IN values in hex")
    frames.add_argument("file", type=Path)
    frames.add_argument("--first", type=int, default=0)
    frames.add_argument("--count", type=int, default=20)
    snap = sub.add_parser("snapshot", help="extract the Nth embedded snapshot")
    snap.add_argument("file", type=Path)
    snap.add_argument("output", type=Path)
    snap.add_argument("--index", type=int, default=0)
    args = parser.parse_args(argv)
    try:
        rzx = read(args.file)
    except (OSError, RzxError) as error:
        print(f"rzx: {args.file}: {error}", file=sys.stderr)
        return 1
    if args.command == "info":
        print(describe(rzx))
    elif args.command == "frames":
        for index, frame in enumerate(rzx.frames()[args.first:args.first + args.count], args.first):
            print(f"{index:6d} {frame.fetches:5d} {frame.inputs.hex(' ')}")
    else:
        embedded = [s for s in rzx.snapshots if s.external_name is None]
        if not 0 <= args.index < len(embedded):
            print(f"rzx: {args.file}: no embedded snapshot {args.index} ({len(embedded)} present)", file=sys.stderr)
            return 1
        args.output.write_bytes(embedded[args.index].data)
        print(f"{args.output}: {embedded[args.index].extension}, {len(embedded[args.index].data)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
