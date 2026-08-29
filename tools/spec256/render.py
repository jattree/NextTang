#!/usr/bin/env python3
"""Render the Spec256 paper from a GFX file and optional background."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Sequence

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.spec256.gfx import (
    GFX_SIZE,
    PLANE_COUNT,
    RAM_SIZE,
    decode_gfx,
    read_exact_file,
)
from tools.spec256.snapshot import parse_snapshot


PAPER_WIDTH = 256
PAPER_HEIGHT = 192
BACKGROUND_WIDTH = 320
BACKGROUND_HEIGHT = 200
BACKGROUND_PAPER_X = (BACKGROUND_WIDTH - PAPER_WIDTH) // 2
BACKGROUND_PAPER_Y = (BACKGROUND_HEIGHT - PAPER_HEIGHT) // 2
BACKGROUND_SIZE = BACKGROUND_WIDTH * BACKGROUND_HEIGHT
MAX_PALETTE_BYTES = 16 * 1024

BITMAP_SIZE = PAPER_WIDTH * PAPER_HEIGHT // 8
ATTRIBUTE_SIZE = (PAPER_WIDTH // 8) * (PAPER_HEIGHT // 8)
SCREEN_SIZE = BITMAP_SIZE + ATTRIBUTE_SIZE

# A graphical value of 0xFF marks a pixel the artist did not recolour, so the
# ordinary Spectrum screen shows through with its attribute colour.  GZX has no
# case for it and paints palette entry 255 instead.
PASSTHROUGH_INDEX = 0xFF

SPECTRUM_PALETTE = (
    (0, 0, 0), (0, 0, 215), (215, 0, 0), (215, 0, 215),
    (0, 215, 0), (0, 215, 215), (215, 215, 0), (215, 215, 215),
    (0, 0, 0), (0, 0, 255), (255, 0, 0), (255, 0, 255),
    (0, 255, 0), (0, 255, 255), (255, 255, 0), (255, 255, 255),
)


def spectrum_screen_offset(line: int, byte_column: int) -> int:
    """Return the Spectrum bitmap offset for one raster line and byte column."""
    if not 0 <= line < PAPER_HEIGHT:
        raise ValueError("line must be between 0 and 191")
    if not 0 <= byte_column < PAPER_WIDTH // 8:
        raise ValueError("byte column must be between 0 and 31")

    linear = line * (PAPER_WIDTH // 8) + byte_column
    return (
        (linear & 0xF81F)
        | ((linear & 0x00E0) << 3)
        | ((linear & 0x0700) >> 3)
    )


def render_paper_indices(
    planes: Sequence[bytes], background: bytes | None = None
) -> bytes:
    """Render the 256x192 paper as one eight-bit palette index per pixel."""
    if len(planes) != PLANE_COUNT or any(len(plane) != RAM_SIZE for plane in planes):
        raise ValueError("rendering requires eight 48 KiB planes")
    if background is not None and len(background) != BACKGROUND_SIZE:
        raise ValueError(
            f"Spec256 background must be exactly {BACKGROUND_SIZE} bytes, "
            f"got {len(background)}"
        )

    output = bytearray(PAPER_WIDTH * PAPER_HEIGHT)
    for line in range(PAPER_HEIGHT):
        for byte_column in range(PAPER_WIDTH // 8):
            address = spectrum_screen_offset(line, byte_column)
            for pixel_in_byte in range(8):
                source_bit = 7 - pixel_in_byte
                colour = 0
                for plane_index, plane in enumerate(planes):
                    colour |= ((plane[address] >> source_bit) & 1) << plane_index

                x = byte_column * 8 + pixel_in_byte
                if colour == 0 and background is not None:
                    background_offset = (
                        (BACKGROUND_PAPER_Y + line) * BACKGROUND_WIDTH
                        + BACKGROUND_PAPER_X
                        + x
                    )
                    colour = background[background_offset]
                output[line * PAPER_WIDTH + x] = colour

    return bytes(output)


def load_palette(path: Path) -> tuple[tuple[int, int, int], ...]:
    """Load the 256-entry decimal RGB palette used by Spec256 and GZX."""
    size = path.stat().st_size
    if size > MAX_PALETTE_BYTES:
        raise ValueError(
            f"Spec256 palette must be no larger than {MAX_PALETTE_BYTES} bytes, "
            f"got {size}"
        )
    with path.open("rb") as stream:
        payload = stream.read(MAX_PALETTE_BYTES + 1)
    if len(payload) > MAX_PALETTE_BYTES:
        raise ValueError("Spec256 palette changed while being read")

    values = [int(value) for value in payload.decode("ascii").split()]
    if len(values) != 256 * 3:
        raise ValueError(f"Spec256 palette must contain 768 values, got {len(values)}")
    if any(not 0 <= value <= 255 for value in values):
        raise ValueError("Spec256 palette values must be between 0 and 255")

    # GZX reduces the source values to VGA's six-bit channels, then expands
    # them for SDL. Reproduce that quantisation for reference comparisons.
    channels = [255 * (value >> 2) // 63 for value in values]
    return tuple(
        (channels[index], channels[index + 1], channels[index + 2])
        for index in range(0, len(channels), 3)
    )


def spectrum_pixel_colour(
    screen: bytes, x: int, y: int, flash_phase: bool = False
) -> tuple[int, int, int]:
    """Return the ordinary Spectrum colour of one pixel of a 6912-byte screen."""
    if len(screen) != SCREEN_SIZE:
        raise ValueError(
            f"Spectrum screen must be exactly {SCREEN_SIZE} bytes, got {len(screen)}"
        )

    byte_column = x // 8
    bit_set = (screen[spectrum_screen_offset(y, byte_column)] >> (7 - (x % 8))) & 1
    attribute = screen[BITMAP_SIZE + (y // 8) * (PAPER_WIDTH // 8) + byte_column]

    ink = attribute & 0x07
    paper = (attribute >> 3) & 0x07
    if flash_phase and (attribute & 0x80):
        ink, paper = paper, ink

    bright = (attribute >> 6) & 1
    return SPECTRUM_PALETTE[bright * 8 + (ink if bit_set else paper)]


def render_paper_rgb(
    planes: Sequence[bytes],
    palette: Sequence[tuple[int, int, int]],
    background: bytes | None = None,
    screen: bytes | None = None,
    flash_phase: bool = False,
) -> bytes:
    """Render the paper as three bytes per pixel, resolving 0xFF passthrough.

    Without a screen this matches GZX, so the existing static pipeline is
    unchanged.  With one, a 0xFF pixel takes the ordinary Spectrum colour it
    would have had on an unmodified machine.
    """
    if len(palette) != 256:
        raise ValueError("rendering requires a 256-entry palette")
    if screen is not None and len(screen) != SCREEN_SIZE:
        raise ValueError(
            f"Spectrum screen must be exactly {SCREEN_SIZE} bytes, got {len(screen)}"
        )

    indices = render_paper_indices(planes, background)
    output = bytearray()
    for y in range(PAPER_HEIGHT):
        for x in range(PAPER_WIDTH):
            index = indices[y * PAPER_WIDTH + x]
            if index == PASSTHROUGH_INDEX and screen is not None:
                output.extend(spectrum_pixel_colour(screen, x, y, flash_phase))
            else:
                output.extend(palette[index])
    return bytes(output)


def write_ppm_rgb(path: Path, width: int, height: int, rgb: bytes) -> None:
    """Write three-bytes-per-pixel data as a dependency-free binary PPM."""
    if len(rgb) != width * height * 3:
        raise ValueError("pixel count does not match image dimensions")
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode("ascii") + rgb)


def write_rgb332_mem_rgb(path: Path, rgb: bytes) -> None:
    """Write one RGB332 hexadecimal byte per line from RGB pixel data."""
    if len(rgb) % 3:
        raise ValueError("RGB data must contain three bytes per pixel")
    values = [
        f"{(rgb[i] & 0xE0) | ((rgb[i + 1] >> 3) & 0x1C) | (rgb[i + 2] >> 6):02x}"
        for i in range(0, len(rgb), 3)
    ]
    path.write_text("\n".join(values) + "\n", encoding="ascii")


def write_ppm(
    path: Path,
    width: int,
    height: int,
    indices: bytes,
    palette: Sequence[tuple[int, int, int]],
) -> None:
    """Write an indexed image as a dependency-free binary PPM."""
    if len(indices) != width * height:
        raise ValueError("pixel count does not match image dimensions")
    if len(palette) != 256:
        raise ValueError("rendering requires a 256-entry palette")

    rgb = bytearray()
    for index in indices:
        rgb.extend(palette[index])
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode("ascii") + rgb)


def write_rgb332_mem(
    path: Path,
    indices: bytes,
    palette: Sequence[tuple[int, int, int]],
) -> None:
    """Write one RGB332 hexadecimal byte per line for FPGA initialisation."""
    if len(palette) != 256:
        raise ValueError("rendering requires a 256-entry palette")

    values = []
    for index in indices:
        red, green, blue = palette[index]
        values.append(f"{(red & 0xE0) | ((green >> 3) & 0x1C) | (blue >> 6):02x}")
    path.write_text("\n".join(values) + "\n", encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="render a user-supplied Spec256 GFX paper to PPM"
    )
    parser.add_argument("gfx", type=Path, help="user-supplied GFX file")
    parser.add_argument("--background", type=Path, help="optional 64000-byte B00")
    parser.add_argument(
        "--snapshot",
        type=Path,
        help="optional 48K SNA supplying the ordinary screen for 0xFF passthrough",
    )
    parser.add_argument(
        "--flash-phase",
        action="store_true",
        help="render the inverted half of the attribute flash cycle",
    )
    parser.add_argument("--palette", type=Path, required=True, help="Spec256 palette")
    parser.add_argument("--output", type=Path, required=True, help="output PPM")
    parser.add_argument(
        "--output-format",
        choices=("ppm", "rgb332-mem"),
        default="ppm",
        help="output encoding (default: ppm)",
    )
    arguments = parser.parse_args()

    try:
        planes = decode_gfx(read_exact_file(arguments.gfx, GFX_SIZE, "Spec256 GFX"))
        background = (
            read_exact_file(arguments.background, BACKGROUND_SIZE, "Spec256 background")
            if arguments.background is not None
            else None
        )
        screen = None
        if arguments.snapshot is not None:
            snapshot = parse_snapshot(arguments.snapshot.read_bytes())
            screen = snapshot.ram[:SCREEN_SIZE]
        palette = load_palette(arguments.palette)
        rgb = render_paper_rgb(
            planes, palette, background, screen, arguments.flash_phase
        )
        if arguments.output_format == "rgb332-mem":
            write_rgb332_mem_rgb(arguments.output, rgb)
        else:
            write_ppm_rgb(arguments.output, PAPER_WIDTH, PAPER_HEIGHT, rgb)
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
