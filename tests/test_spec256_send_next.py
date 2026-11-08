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
from add_bgx2 import add_bgx2  # noqa: E402
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

    def test_zxpoly_mode(self) -> None:
        game = bytearray(send_next.RUL1_AT + 72)
        self.assertEqual(send_next.game_zxpoly_mode(bytes(game)), 0)
        game[send_next.RUL1_AT : send_next.RUL1_AT + 8] = b"RUL1\x01\x00\x01\x07"
        self.assertEqual(send_next.game_zxpoly_mode(bytes(game)), 7)

    def test_128k_snapshot_pc_is_in_the_extension(self) -> None:
        sna = bytearray(send_next.SNA_128K_SIZE)
        sna[49_179:49_181] = b"\x2d\x96"
        self.assertEqual(send_next.snapshot_pc(bytes(sna)), 0x962D)

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


class Bgx2Test(unittest.TestCase):
    """The tool's file and what the sender makes of it."""

    def game(self, size: int = send_next.OPT1_AT) -> bytes:
        return bytes(size)

    def image(self, value: int) -> bytes:
        return bytes((value,)) * send_next.BACKGROUND_BYTES

    def test_existing_bytes_stay_and_opt1_is_added(self) -> None:
        game = bytes(i & 0xFF for i in range(send_next.OPT1_AT))
        out = add_bgx2(game, [self.image(1)], ["4:17d1b,=1,ff,0c,19"])
        self.assertEqual(out[:send_next.OPT1_AT], game)
        self.assertEqual(out[send_next.OPT1_AT:send_next.OPT1_AT + 5], b"OPT1\x01")
        self.assertEqual(out[send_next.TAGGED_BLOCKS_AT:send_next.TAGGED_BLOCKS_AT + 4], b"BGX2")

    def test_existing_opt1_and_blocks_are_kept(self) -> None:
        game = bytearray(send_next.TAGGED_BLOCKS_AT)
        game[send_next.OPT1_AT:send_next.OPT1_AT + 9] = b"OPT1\x01\0\0\0\x01"
        game += b"XYZ9" + (3).to_bytes(4, "little") + b"abc"
        out = add_bgx2(bytes(game), [self.image(1)], [])
        self.assertEqual(out[:len(game)], bytes(game))
        self.assertIsNotNone(send_next.game_bgx2(out))

    def test_layout(self) -> None:
        out = add_bgx2(self.game(), [self.image(1), self.image(0), self.image(3)],
                       ["none:17d1b,=1,ff,0c,19", "6:00100,>=2,ffff,1234,5678:00200,!=1,f0,10,20"], "keep")
        at = send_next.TAGGED_BLOCKS_AT
        length = 4 + 3 * send_next.BACKGROUND_BYTES + 2 * 64
        self.assertEqual(out[at + 4:at + 8], length.to_bytes(4, "little"))
        self.assertEqual(len(out), at + 8 + length)
        self.assertEqual(out[at + 8:at + 12], bytes((3, 2, 0xFF, 0)))
        rules_at = at + 12 + 3 * send_next.BACKGROUND_BYTES
        self.assertEqual(out[rules_at:rules_at + 18],
                         bytes((0xFE, 0, 0x1B, 0x7D, 0x01, 0x11, 0xFF, 0, 0, 0, 0x0C, 0, 0, 0, 0x19, 0, 0, 0)))
        second = out[rules_at + 64:rules_at + 128]
        self.assertEqual(second[0], 6)
        self.assertEqual(second[2:18], bytes((0, 1, 0, 0x42, 0xFF, 0xFF, 0, 0, 0x34, 0x12, 0, 0, 0x78, 0x56, 0, 0)))
        self.assertEqual(second[18:34], bytes((0, 2, 0, 0x21, 0xF0, 0, 0, 0, 0x10, 0, 0, 0, 0x20, 0, 0, 0)))
        self.assertEqual(second[34:], bytes(30))
        header, images = send_next.game_bgx2(out)
        self.assertEqual(header[:4], bytes((3, 2, 0xFF, 0)))
        self.assertEqual(len(header), 4 + 128)
        # The empty background is not sent; numbering still counts it.
        self.assertEqual([number for number, _ in images], [4, 6])

    def test_b00_keeps_the_paper(self) -> None:
        b00 = bytes((y * 320 + x) % 251 for y in range(200) for x in range(320))
        out = add_bgx2(self.game(), [b00], [])
        _, images = send_next.game_bgx2(out)
        paper = images[0][1]
        self.assertEqual(len(paper), send_next.BACKGROUND_BYTES)
        self.assertEqual(paper[0], (4 * 320 + 32) % 251)
        self.assertEqual(paper[256 * 191 + 255], (195 * 320 + 287) % 251)

    def test_refuses_what_the_format_does_not_allow(self) -> None:
        image = self.image(1)
        for images, rules, default in (([], [], "keep"), ([image] * 29, [], "keep"),
                                       ([image], ["4:1,=1,ff,0,0"] * 65, "keep"),
                                       ([image], ["5:1,=1,ff,0,0"], "keep"),
                                       ([image], ["1:1,=5,ff,0,0"], "keep"),
                                       ([image], ["1:20000,=1,ff,0,0"], "keep"),
                                       ([image], [], "5"), ([bytes(100)], [], "keep"),
                                       ([image], [f"1:{n:x},=1,ff,0,0" for n in range(17)], "keep")):
            with self.assertRaises(ValueError):
                add_bgx2(self.game(), images, rules, default)
        with self.assertRaises(ValueError):
            add_bgx2(self.game(send_next.OPT1_AT - 1), [image], [])
        with self.assertRaises(ValueError):
            add_bgx2(add_bgx2(self.game(), [image], []), [image], [])

    def test_stream_order(self) -> None:
        game = bytearray(send_next.OPT1_AT)
        game[send_next.BGX1_AT:send_next.BGX1_AT + 8] = b"BGX1" + bytes((4, 1, 0xFF, 0))
        image_1 = send_next.BGX1_IMAGES_AT
        game[image_1:image_1 + send_next.BACKGROUND_BYTES] = self.image(9)
        out = add_bgx2(bytes(game), [self.image(1)], ["4:17d1b,=1,ff,0c,19"], "none")
        palette = bytes(512)
        stream = send_next.game_colour_stream(out, palette)
        at_l = stream.index(b"L\x01\x01\xfe\x00")
        at_m = stream.index(b"M1\x09")
        at_a = stream.index(b"A04\x01")
        self.assertLess(at_l, at_m)
        self.assertLess(at_m, at_a)
        self.assertNotIn(b"E\x04\x01\xff", stream)
        old = send_next.game_colour_stream(out, palette, level2=False)
        self.assertIn(b"E\x04\x01\xff", old)
        self.assertNotIn(b"A04\x01", old)
        self.assertEqual(old, send_next.game_colour_stream(bytes(game), palette))


if __name__ == "__main__":
    unittest.main()
