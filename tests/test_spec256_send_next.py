"""The Spec256 UART sender must lay out plane words as the board reads them.

tools/spec256/send_next.py sends, for each Spectrum address from 0x4000,
eight bytes with plane 0's first; the loader shifts them into a 64-bit word
low byte first, and the overlay takes colour index bit k of pixel x from bit
8k + (7 - x % 8) of the word. Rendering a synthetic GFX through that path
must give the indices tools/spec256/render.py gives, the reference checked
against GZX in Episode 5. The palette goes as 256 RGB333 entries, low byte
first.

From a .256 (SPEC256_MISTER's format: nine bytes per address of eight 16K
banks, plane 0 first, master byte last) the same words come from banks 5, 2
and 0, the rules flags from RUL1, or 0 when the file has none, and the ROM
character set's words from GRX1 when it is there.
"""

from pathlib import Path
import random
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools" / "spec256"))
import send_next  # noqa: E402
from gfx import GFX_SIZE, decode_gfx  # noqa: E402
from render import render_paper_indices, spectrum_screen_offset  # noqa: E402


class SendNextTest(unittest.TestCase):
    def test_plane_words_match_the_reference_render(self) -> None:
        generator = random.Random(256)
        gfx = bytes(generator.randrange(256) for _ in range(GFX_SIZE))
        words = send_next.plane_words(gfx)
        self.assertEqual(len(words), 49_152 * 8)
        reference = render_paper_indices(decode_gfx(gfx))
        for y in (0, 7, 8, 63, 64, 100, 191):
            for x in (0, 1, 7, 8, 129, 255):
                offset = spectrum_screen_offset(y, x // 8)
                word = int.from_bytes(words[offset * 8 : offset * 8 + 8], "little")
                index = 0
                for k in range(8):
                    index |= ((word >> (8 * k + 7 - x % 8)) & 1) << k
                self.assertEqual(index, reference[y * 256 + x], (x, y))

    def test_game_planes_come_from_the_48k_banks(self) -> None:
        generator = random.Random(9)
        gfx = bytes(generator.randrange(256) for _ in range(GFX_SIZE))
        planes = decode_gfx(gfx)
        game = bytearray(generator.randrange(256) for _ in range(send_next.RUL1_AT + 72))
        for address in range(0x4000, 0x10000):
            bank = (5, 2, 0)[(address >> 14) - 1]
            at = bank * send_next.BANK_BYTES + (address & 0x3FFF) * 9
            game[at : at + 8] = bytes(plane[address - 0x4000] for plane in planes)
        game = bytes(game)
        self.assertEqual(send_next.game_plane_words(game), send_next.plane_words(gfx))
        with self.assertRaises(ValueError):
            send_next.game_plane_words(game[: send_next.GAME_MIN_SIZE - 1])

    def test_rules_flags_need_rul1_version_1(self) -> None:
        game = bytearray(send_next.RUL1_AT + 72)
        self.assertEqual(send_next.game_rules_flags(bytes(game)), 0)
        game[send_next.RUL1_AT : send_next.RUL1_AT + 6] = b"RUL1\x01\x03"
        self.assertEqual(send_next.game_rules_flags(bytes(game)), 3)
        game[send_next.RUL1_AT + 4] = 2
        self.assertEqual(send_next.game_rules_flags(bytes(game)), 0)

    def test_rom_font_comes_from_grx1(self) -> None:
        game = bytearray(send_next.RUL1_AT + 72)
        self.assertIsNone(send_next.game_rom_font_words(bytes(game)))
        font = bytes((i * 7 + 3) & 0xFF for i in range(768 * 8))
        game[send_next.GRX1_AT : send_next.GRX1_AT + 4] = b"GRX1"
        game[send_next.GRX1_AT + 4 : send_next.GRX1_AT + 4 + len(font)] = font
        self.assertEqual(send_next.game_rom_font_words(bytes(game)), font)
        self.assertEqual(send_next.GRX1_AT + 4 + len(font), send_next.RUL1_AT)

    def test_background_and_cfg(self) -> None:
        game = bytearray(send_next.RUL1_AT + 72)
        self.assertIsNone(send_next.game_background(bytes(game)))
        game[send_next.CFG_AT : send_next.CFG_AT + 3] = b"\x40\x00\x88"
        game[send_next.BACKGROUND_AT + 5] = 9
        background = send_next.game_background(bytes(game))
        self.assertEqual(len(background), 256 * 192)
        self.assertEqual(background[5], 9)
        self.assertEqual(send_next.game_cfg(bytes(game)), b"\x40\x00\x88")
        self.assertEqual(send_next.BACKGROUND_AT + 256 * 192, 1_228_832)

    def test_rules_need_rul1_with_rules(self) -> None:
        game = bytearray(send_next.RUL1_AT + 72)
        game[send_next.RUL1_AT : send_next.RUL1_AT + 8] = b"RUL1\x01\x00\x00\x00"
        self.assertIsNone(send_next.game_rules(bytes(game)))
        game[send_next.RUL1_AT + 6] = 2
        game[send_next.RUL1_AT + 8 : send_next.RUL1_AT + 16] = bytes((0xFC, 0xFC, 0, 0, 1, 0, 0, 0))
        rules = send_next.game_rules(bytes(game))
        self.assertEqual(len(rules), 64)
        self.assertEqual(rules[:8], bytes((0xFC, 0xFC, 0, 0, 1, 0, 0, 0)))

    def test_palette_is_rgb333_low_byte_first(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.pal"
            values = [0] * 768
            values[3:6] = [255, 0, 0]     # entry 1: red
            values[765:768] = [0, 255, 255]  # entry 255: cyan
            path.write_text(" ".join(map(str, values)))
            palette = send_next.palette_bytes(path)
        self.assertEqual(len(palette), 512)
        self.assertEqual(palette[2:4], bytes((0xC0, 0x01)))  # 0b111_000_000
        self.assertEqual(palette[510:512], bytes((0x3F, 0x00)))  # 0b000_111_111


if __name__ == "__main__":
    unittest.main()
