"""Regression tests for Spec256 palette index 0xFF passthrough.

Index 0xFF means the artist did not recolour that pixel, so the ordinary
Spectrum screen and its attribute colour show through.  GZX has no 0xFF case
and paints `sp256.pal` entry 255, a sentinel pure red, which is why Chuckie
Egg's title renders red on hardware that faithfully reproduces GZX.
"""

from pathlib import Path
import sys
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from tools.spec256.gfx import PLANE_COUNT, RAM_SIZE  # noqa: E402
from tools.spec256.render import (  # noqa: E402
    PASSTHROUGH_INDEX,
    SCREEN_SIZE,
    SPECTRUM_PALETTE,
    PAPER_WIDTH,
    render_paper_rgb,
    spectrum_pixel_colour,
    spectrum_screen_offset,
)


def flat_palette() -> tuple[tuple[int, int, int], ...]:
    """A palette where every index maps to a distinguishable colour."""
    return tuple((index, 0, 0) for index in range(256))


def planes_with(value: int, line: int, byte_column: int, bit: int):
    """Eight planes encoding one pixel at `value` and everything else zero."""
    planes = [bytearray(RAM_SIZE) for _ in range(PLANE_COUNT)]
    address = spectrum_screen_offset(line, byte_column)
    for plane_index in range(PLANE_COUNT):
        if (value >> plane_index) & 1:
            planes[plane_index][address] |= 1 << (7 - bit)
    return [bytes(plane) for plane in planes]


def screen_with(attribute: int, line: int, byte_column: int, ink_bits: int) -> bytes:
    """A 6912-byte screen with one byte of bitmap and one attribute cell set."""
    screen = bytearray(SCREEN_SIZE)
    screen[spectrum_screen_offset(line, byte_column)] = ink_bits
    screen[6144 + (line // 8) * 32 + byte_column] = attribute
    return bytes(screen)


class Spec256PassthroughTests(unittest.TestCase):
    def pixel(self, rgb: bytes, x: int, y: int) -> tuple[int, int, int]:
        offset = (y * PAPER_WIDTH + x) * 3
        return tuple(rgb[offset : offset + 3])

    def test_passthrough_pixel_takes_the_ordinary_ink_colour(self) -> None:
        # Attribute 0x07: white ink, black paper, not bright.
        planes = planes_with(PASSTHROUGH_INDEX, line=0, byte_column=0, bit=0)
        screen = screen_with(0x07, line=0, byte_column=0, ink_bits=0x80)

        rgb = render_paper_rgb(planes, flat_palette(), screen=screen)

        self.assertEqual(self.pixel(rgb, 0, 0), SPECTRUM_PALETTE[7])

    def test_passthrough_pixel_takes_the_ordinary_paper_colour(self) -> None:
        # Same cell, but this pixel's bitmap bit is clear, so paper shows.
        planes = planes_with(PASSTHROUGH_INDEX, line=0, byte_column=0, bit=1)
        screen = screen_with(0x0F, line=0, byte_column=0, ink_bits=0x80)

        rgb = render_paper_rgb(planes, flat_palette(), screen=screen)

        # Attribute 0x0F: white ink, blue paper.  Bit 1 is clear -> paper.
        self.assertEqual(self.pixel(rgb, 1, 0), SPECTRUM_PALETTE[1])

    def test_passthrough_honours_the_bright_bit(self) -> None:
        planes = planes_with(PASSTHROUGH_INDEX, line=0, byte_column=0, bit=0)
        screen = screen_with(0x47, line=0, byte_column=0, ink_bits=0x80)

        rgb = render_paper_rgb(planes, flat_palette(), screen=screen)

        self.assertEqual(self.pixel(rgb, 0, 0), SPECTRUM_PALETTE[8 + 7])

    def test_recoloured_pixel_ignores_the_ordinary_screen(self) -> None:
        # Index 27 is a real recolour and must not be replaced.
        planes = planes_with(27, line=0, byte_column=0, bit=0)
        screen = screen_with(0x07, line=0, byte_column=0, ink_bits=0x80)

        rgb = render_paper_rgb(planes, flat_palette(), screen=screen)

        self.assertEqual(self.pixel(rgb, 0, 0), (27, 0, 0))

    def test_without_a_screen_the_sentinel_colour_is_kept(self) -> None:
        # Matches GZX exactly when no ordinary screen is supplied, so the
        # existing static pipeline keeps its current behaviour.
        planes = planes_with(PASSTHROUGH_INDEX, line=0, byte_column=0, bit=0)

        rgb = render_paper_rgb(planes, flat_palette())

        self.assertEqual(self.pixel(rgb, 0, 0), (255, 0, 0))

    def test_screen_must_be_the_documented_size(self) -> None:
        planes = planes_with(PASSTHROUGH_INDEX, line=0, byte_column=0, bit=0)
        with self.assertRaisesRegex(ValueError, "6912"):
            render_paper_rgb(planes, flat_palette(), screen=b"\x00" * 6911)

    def test_flash_phase_swaps_ink_and_paper(self) -> None:
        # Attribute 0x87: flash set, white ink, black paper.
        planes = planes_with(PASSTHROUGH_INDEX, line=0, byte_column=0, bit=0)
        screen = screen_with(0x87, line=0, byte_column=0, ink_bits=0x80)

        steady = render_paper_rgb(planes, flat_palette(), screen=screen)
        flashed = render_paper_rgb(
            planes, flat_palette(), screen=screen, flash_phase=True
        )

        self.assertEqual(self.pixel(steady, 0, 0), SPECTRUM_PALETTE[7])
        self.assertEqual(self.pixel(flashed, 0, 0), SPECTRUM_PALETTE[0])

    def test_pixel_colour_helper_matches_ula_addressing(self) -> None:
        # Line 64 is the start of the third screen third; an addressing slip
        # here draws a stable but wrong cell.
        screen = screen_with(0x06, line=64, byte_column=5, ink_bits=0x20)

        self.assertEqual(spectrum_pixel_colour(screen, 5 * 8 + 2, 64),
                         SPECTRUM_PALETTE[6])
        self.assertEqual(spectrum_pixel_colour(screen, 5 * 8 + 3, 64),
                         SPECTRUM_PALETTE[0])


if __name__ == "__main__":
    unittest.main()
