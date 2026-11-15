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
        regs, ram = play.parse_z80_v1(capture.z80_v1(REGS, RAM))
        self.assertEqual(regs, REGS)
        self.assertEqual(ram, RAM)

    def test_other_z80_versions_are_refused(self) -> None:
        data = bytearray(capture.z80_v1(REGS, RAM))
        data[6:8] = b"\x00\x00"                    # PC 0: a version 2 or 3 file
        with self.assertRaises(ValueError):
            play.parse_z80_v1(bytes(data))

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

    def test_stream_bytes(self) -> None:
        frame = play.Frame(0x1CDA, bytes([0xBF, 0xFE, 0x00]))
        self.assertEqual(play.frame_bytes(frame), bytes([0xDA, 0x1C, 3, 0, 0xBF, 0xFE, 0x00]))
        self.assertEqual(play.escaped(play.frame_bytes(frame)), bytes([0xDA, 0x1C, 3, 0, 0xBF, 0xFE, 0x00, 0x00]))


if __name__ == "__main__":
    unittest.main()
