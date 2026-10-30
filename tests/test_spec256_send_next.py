"""The Spec256 UART sender must lay out plane words as the board reads them.

tools/spec256/send_next.py sends, for each Spectrum address from 0x4000,
eight bytes with plane 0's first; the loader shifts them into a 64-bit word
low byte first, and the overlay takes colour index bit k of pixel x from bit
8k + (7 - x % 8) of the word. Rendering a synthetic GFX through that path
must give the indices tools/spec256/render.py gives, the reference checked
against GZX in Episode 5. The palette goes as 256 RGB333 entries, low byte
first.
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
