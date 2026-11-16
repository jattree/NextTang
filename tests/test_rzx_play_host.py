"""Snapshot readers and stream helpers of host/rzx_play.py."""

from __future__ import annotations

import importlib.util
import struct
import sys
import unittest
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / "host" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


play = load("rzx_play")
capture = load("rzx_capture")

REGS = {"AF": 0x1234, "BC": 0x2345, "DE": 0x3456, "HL": 0x4567, "AF'": 0x5678, "BC'": 0x6789,
        "DE'": 0x789A, "HL'": 0x89AB, "IX": 0x9ABC, "IY": 0xABCD, "SP": 0xFF4C, "PC": 0x15E6,
        "I": 0x3F, "R": 0x89, "IFF1": 1, "IFF2": 1, "IM": 1}
RAM = bytes((n * 7 + (n >> 8)) & 0xFF for n in range(0xC000))


def szx(regs: dict[str, int], ram: bytes, machine: int = 1, halted: bool = False, compress: bool = True) -> bytes:
    def chunk(name: bytes, body: bytes) -> bytes:
        return name + struct.pack("<I", len(body)) + body
    z80r = struct.pack("<12H5B", regs["AF"], regs["BC"], regs["DE"], regs["HL"], regs["AF'"], regs["BC'"],
                       regs["DE'"], regs["HL'"], regs["IX"], regs["IY"], regs["SP"], regs["PC"],
                       regs["I"], regs["R"], regs["IFF1"], regs["IFF2"], regs["IM"])
    z80r += struct.pack("<IBBH", 0, 0, 2 if halted else 0, 0)
    out = b"ZXST" + bytes([1, 5, machine, 0]) + chunk(b"CRTR", b"x" * 36) + chunk(b"Z80R", z80r)
    for page, offset in ((0, 0x8000), (2, 0x4000), (5, 0)):       # any order
        raw = ram[offset:offset + 0x4000]
        out += chunk(b"RAMP", struct.pack("<HB", 1 if compress else 0, page) + (zlib.compress(raw) if compress else raw))
    return out


class RzxPlayHostTest(unittest.TestCase):
    def test_z80_written_by_the_capture_tool_reads_back(self) -> None:
        regs, ram = play.parse_z80(capture.z80_v1(REGS, RAM))
        self.assertEqual(regs, REGS)
        self.assertEqual(ram, RAM)

    def test_z80_version_1_compressed(self) -> None:
        ram = bytes(100) + b"\xed\xed" + RAM[102:0xC000 - 50] + b"\x55" * 50
        packed = bytearray()
        at = 0
        while at < len(ram):                       # a simple packer: runs of 5 or more, and any ED ED
            run = 1
            while at + run < len(ram) and ram[at + run] == ram[at] and run < 255:
                run += 1
            if run >= 5 or (ram[at] == 0xED and run >= 2):
                packed += bytes([0xED, 0xED, run, ram[at]])
                at += run
            else:
                packed.append(ram[at])
                at += 1
                if ram[at - 1] == 0xED and at < len(ram):   # a byte after a lone ED is never packed
                    packed.append(ram[at])
                    at += 1
        header = bytearray(capture.z80_v1(REGS, RAM)[:30])
        header[12] |= 0x20
        regs, got = play.parse_z80(bytes(header) + bytes(packed) + b"\x00\xed\xed\x00")
        self.assertEqual(regs, REGS)
        self.assertEqual(got, ram)

    def test_z80_version_3(self) -> None:
        header = bytearray(capture.z80_v1(REGS, RAM)[:30])
        header[6:8] = b"\x00\x00"
        extra = struct.pack("<HHB", 54, REGS["PC"], 0) + bytes(51)
        blocks = b""
        for page, offset in ((4, 0x4000), (5, 0x8000), (8, 0)):
            blocks += struct.pack("<HB", 0xFFFF, page) + RAM[offset:offset + 0x4000]
        regs, ram = play.parse_z80(bytes(header) + extra + blocks)
        self.assertEqual(regs, REGS)
        self.assertEqual(ram, RAM)
        with self.assertRaises(ValueError):       # hardware 4: a 128K
            play.parse_z80(bytes(header) + struct.pack("<HHB", 54, REGS["PC"], 4) + bytes(51) + blocks)

    def test_szx_48k(self) -> None:
        for compress in (True, False):
            regs, ram = play.parse_szx_48k(szx(REGS, RAM, compress=compress))
            self.assertEqual(regs, REGS)
            self.assertEqual(ram, RAM)

    def test_szx_refusals(self) -> None:
        with self.assertRaises(ValueError):
            play.parse_szx_48k(szx(REGS, RAM, machine=2))      # a 128K
        with self.assertRaises(ValueError):
            play.parse_szx_48k(szx(REGS, RAM, halted=True))
        with self.assertRaises(ValueError):
            play.parse_szx_48k(b"ZXST" + bytes([1, 5, 1, 0]))  # no chunks

    def test_z80_128k(self) -> None:
        banks = [bytes([number * 16 + 1]) * 0x4000 for number in range(8)]
        header = bytearray(capture.z80_v1(REGS, RAM)[:30])
        header[6:8] = b"\x00\x00"
        ay = bytes(range(0x40, 0x50))

        def extra(length: int, hardware: int, modify: int = 0) -> bytes:
            body = bytearray(length)
            body[0:2] = struct.pack("<H", REGS["PC"])
            body[2], body[3], body[5], body[6] = hardware, 0x17, modify, 0x0B
            body[7:23] = ay
            return struct.pack("<H", length) + bytes(body)

        blocks = b""
        for number in (7, 0, 3, 1, 2, 6, 5, 4):                 # any order
            blocks += struct.pack("<HB", 0xFFFF, number + 3) + banks[number]
        for length, hardware, modify, model in ((54, 4, 0, "128"), (23, 3, 0, "128"), (54, 4, 0x80, "plus2"),
                                                (55, 12, 0, "plus2")):
            data = bytes(header) + extra(length, hardware, modify) + blocks
            self.assertEqual(play.z80_model(data), model)
            snap = play.parse_z80_128(data)
            self.assertEqual((snap.model, snap.regs, snap.banks), (model, REGS, banks))
            self.assertEqual((snap.port_7ffd, snap.ay, snap.ay_register), (0x17, ay, 0x0B))
        self.assertEqual(play.z80_model(bytes(header) + extra(54, 7) + blocks), "plus3")
        plus3 = bytearray(bytes(header) + extra(55, 7) + blocks)
        plus3[86] = 0x04
        snap = play.parse_z80_128(bytes(plus3))
        self.assertEqual((snap.model, snap.port_7ffd, snap.port_1ffd, snap.banks), ("plus3", 0x17, 0x04, banks))
        self.assertEqual(play.z80_model(bytes(header) + extra(54, 0) + blocks), "48")
        self.assertEqual(play.z80_model(capture.z80_v1(REGS, RAM)), "48")
        with self.assertRaises(ValueError):                      # a Pentagon
            play.parse_z80_128(bytes(header) + extra(54, 9) + blocks)
        with self.assertRaises(ValueError):                      # a bank missing
            play.parse_z80_128(bytes(header) + extra(54, 4) + blocks[:-0x4003])

    def test_szx_128k(self) -> None:
        def chunk(name: bytes, body: bytes) -> bytes:
            return name + struct.pack("<I", len(body)) + body
        banks = [bytes([number * 16 + 2]) * 0x4000 for number in range(8)]
        ay = bytes(range(0x60, 0x70))
        base = szx(REGS, RAM, machine=2)[:8 + 8 + 36 + 8 + 37]   # header, CRTR, Z80R
        rest = chunk(b"SPCR", bytes([7, 0x1D, 0, 0xFF, 0, 0, 0, 0])) + chunk(b"AY\x00\x00", bytes([0, 0x0E]) + ay)
        for number in (5, 2, 0, 1, 3, 4, 6, 7):
            rest += chunk(b"RAMP", struct.pack("<HB", 1, number) + zlib.compress(banks[number]))
        snap = play.parse_szx_128(base + rest)
        self.assertEqual((snap.model, snap.regs, snap.banks), ("128", REGS, banks))
        self.assertEqual((snap.port_7ffd, snap.ay, snap.ay_register), (0x1D, ay, 0x0E))
        plus2 = bytearray(base + rest)
        plus2[6] = 3
        self.assertEqual(play.parse_szx_128(bytes(plus2)).model, "plus2")
        plus2[6] = 5                                             # a +3: port 1FFD from SPCR
        self.assertEqual((play.parse_szx_128(bytes(plus2)).model, play.parse_szx_128(bytes(plus2)).port_1ffd), ("plus3", 0))
        plus2[6] = 7
        with self.assertRaises(ValueError):                      # a Pentagon
            play.parse_szx_128(bytes(plus2))
        with self.assertRaises(ValueError):                      # no paging port
            play.parse_szx_128(base + rest[16:])

    def test_setup_routine(self) -> None:
        code, loop = play.setup_routine(2, [(0xFFFD, 7), (0x7FFD, 0x30)], 0x8200)
        self.assertEqual(code, bytes(8) + bytes([0xF3, 0xED, 0x5E,
                                      0x01, 0xFD, 0xFF, 0x3E, 0x07, 0xED, 0x79,
                                      0x01, 0xFD, 0x7F, 0x3E, 0x30, 0xED, 0x79,
                                      0x21, 0x00, 0x00, 0x11, 0x00, 0x82, 0x01, 0x10, 0x00, 0xED, 0xB0,
                                      0x76]))
        self.assertEqual(loop, len(code) - 1)

    def test_stream_bytes(self) -> None:
        frame = play.Frame(0x1CDA, bytes([0xBF, 0xFE, 0x00]))
        self.assertEqual(play.frame_bytes(frame), bytes([0xDA, 0x1C, 3, 0, 0xBF, 0xFE, 0x00]))
        self.assertEqual(play.escaped(play.frame_bytes(frame)), bytes([0xDA, 0x1C, 3, 0, 0xBF, 0xFE, 0x00, 0x00]))


if __name__ == "__main__":
    unittest.main()
