"""A .256's master state must turn back into the snapshot the Next loads.

tools/spec256/sna_from_256.py writes the uncoloured snapshot the NextZXOS
browser loads while send_next.py sends the colour. make256 starts a game from
a snapshot at PC 0x0072 (the 48K ROM's RETN) with SP on the stacked PC, so
that state goes back with memory and SP unchanged; another PC is pushed below
SP; a game without the paging lock becomes a 128K snapshot whose extension
holds PC and 7FFD and whose banks follow the format's order.
"""

from __future__ import annotations

from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools" / "spec256"))
import sna_from_256 as tool  # noqa: E402


def game(pc: int, sp: int, port_7ffd: int) -> bytes:
    """A .256 whose master byte at bank b, offset o is (b * 31 + o) & 0xFF."""
    out = bytearray(tool.STATE_AT + 29)
    for bank in range(8):
        for offset in range(0, tool.BANK):
            out[(bank * tool.BANK + offset) * 9 + 8] = (bank * 31 + offset) & 0xFF
    state = struct.pack("<HH", 0x1234, 0x5678) + bytes((0x3F, 0x42))
    state += struct.pack("<10H", sp, pc, 0x0BC0, 0x0DE0, 0x0480, 0x1100, 0x2BC0, 0x2DE0, 0x2480, 0x5C3A)
    state += bytes((0b1101, 0x05, port_7ffd))
    out[tool.STATE_AT : tool.STATE_AT + 29] = state
    return bytes(out)


def master(bank: int) -> bytes:
    return bytes((bank * 31 + offset) & 0xFF for offset in range(tool.BANK))


class SnaFrom256Test(unittest.TestCase):
    def check_header(self, sna: bytes, sp: int) -> None:
        self.assertEqual(sna[0], 0x3F)                                    # I
        self.assertEqual(struct.unpack_from("<4H", sna, 1), (0x2480, 0x2DE0, 0x2BC0, 0x5678))
        self.assertEqual(struct.unpack_from("<5H", sna, 9), (0x0480, 0x0DE0, 0x0BC0, 0x5C3A, 0x1100))
        self.assertEqual(sna[19], 0x04)                                   # IFF2
        self.assertEqual(sna[20], 0x42)                                   # R
        self.assertEqual(struct.unpack_from("<HH", sna, 21), (0x1234, sp))
        self.assertEqual((sna[25], sna[26]), (1, 5))                      # IM, border

    def test_retn_start_goes_back_unchanged(self) -> None:
        sna = tool.snapshot(game(tool.RETN_IN_ROM, 0x5CE0, 0x30))
        self.assertEqual(len(sna), 49179)
        self.check_header(sna, 0x5CE0)
        self.assertEqual(sna[27:], master(5) + master(2) + master(0))

    def test_other_pc_is_pushed(self) -> None:
        sna = tool.snapshot(game(0x8000, 0xFF00, 0x30))
        self.check_header(sna, 0xFEFE)
        memory = bytearray(master(5) + master(2) + master(0))
        memory[0xFEFE - 0x4000 : 0xFF00 - 0x4000] = b"\x00\x80"
        self.assertEqual(sna[27:], bytes(memory))

    def test_128k_layout(self) -> None:
        sna = tool.snapshot(game(0x8000, 0xFF00, 0x13))
        self.assertEqual(len(sna), 131103)
        self.check_header(sna, 0xFF00)
        body = sna[27:]
        self.assertEqual(body[: 3 * tool.BANK], master(5) + master(2) + master(3))
        self.assertEqual(body[3 * tool.BANK : 3 * tool.BANK + 4], b"\x00\x80\x13\x00")
        rest = body[3 * tool.BANK + 4 :]
        self.assertEqual(rest, b"".join(master(b) for b in (0, 1, 4, 6, 7)))


if __name__ == "__main__":
    unittest.main()
