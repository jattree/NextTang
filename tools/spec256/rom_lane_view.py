#!/usr/bin/env python3
"""Render what the ROM-lane diagnostic build must put on screen.

`NEXTTANG_SPEC256_ROM_LANE_VIEW` holds every CPU and routes the eight graphical
ROM lanes to the display in place of the graphical planes. With no CPU running,
successive frames are identical by construction, so frame stability proves
nothing here -- the capture is only worth taking if there is something to
compare it against. This produces that reference straight from the pack.

The hardware reads each lane at `{half, display_address[12:0]}`, and the display
address is `{3'b010, bitmap_offset}` where the offset comes from the ordinary
Spectrum screen layout. So the byte shown for a pixel is

    rom_lane[half * 8192 + spectrum_screen_offset(line, byte_column)]

assembled across the eight lanes into one palette index per pixel, exactly as
the planes are assembled in normal operation.

The screen window is 6,912 bytes inside an 8 KiB half, so one build shows
6,912 of each lane's 16,384 bytes; the two halves together cover 13,824, and
bytes 6,912..8,191 and 15,104..16,383 of each lane are never displayed. That is
enough to catch a lane that is zero, shifted, swapped with another lane, or
holding plane data instead of ROM data, which is the question being asked.

Usage:
    python3 tools/spec256/rom_lane_view.py PACK.ntsp reference.ppm [--half 1]
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.spec256.render import (
    BACKGROUND_PAPER_X,
    BACKGROUND_PAPER_Y,
    BACKGROUND_WIDTH,
    PAPER_HEIGHT,
    PAPER_WIDTH,
    PASSTHROUGH_INDEX,
    spectrum_pixel_colour,
    spectrum_screen_offset,
    write_ppm_rgb,
)

# Payload layout, matching nexttang_spec256_game_loader.v.
HEADER_BYTES = 32
BOOT_BYTES = 16 * 1024
MAIN_BYTES = 48 * 1024
BITMAP_BYTES = 6144
ATTRIBUTE_BYTES = 768
GRAPHICS_RAM_BYTES = 8 * 48 * 1024
GRAPHICS_ROM_BYTES = 8 * 16 * 1024
PALETTE_BYTES = 768

MAIN_OFFSET = BOOT_BYTES
GRAPHICS_ROM_OFFSET = BOOT_BYTES + MAIN_BYTES + GRAPHICS_RAM_BYTES
PALETTE_OFFSET = GRAPHICS_ROM_OFFSET + GRAPHICS_ROM_BYTES
BACKGROUND_OFFSET = PALETTE_OFFSET + PALETTE_BYTES
BACKGROUND_BYTES = 64000

LANE_BYTES = 16 * 1024
LANE_COUNT = 8
HALF_BYTES = 8 * 1024


def read_pack(path: Path) -> bytes:
    payload = path.read_bytes()
    if len(payload) < HEADER_BYTES + PALETTE_OFFSET + PALETTE_BYTES:
        raise SystemExit(
            f"{path}: too short to be a Spec256 pack "
            f"({len(payload)} bytes)"
        )
    if payload[:4] != b"NTSP":
        raise SystemExit(f"{path}: missing NTSP magic")
    return payload[HEADER_BYTES:]


def rom_lanes(payload: bytes) -> tuple[bytes, ...]:
    section = payload[GRAPHICS_ROM_OFFSET:GRAPHICS_ROM_OFFSET + GRAPHICS_ROM_BYTES]
    return tuple(
        section[lane * LANE_BYTES:(lane + 1) * LANE_BYTES]
        for lane in range(LANE_COUNT)
    )


def palette(payload: bytes) -> tuple[tuple[int, int, int], ...]:
    raw = payload[PALETTE_OFFSET:PALETTE_OFFSET + PALETTE_BYTES]
    return tuple(
        (raw[index * 3], raw[index * 3 + 1], raw[index * 3 + 2])
        for index in range(256)
    )


def render(lanes: tuple[bytes, ...], half: int, payload: bytes) -> bytes:
    """One palette index per pixel, as nexttang_spec256_display.v produces it.

    The display does not show the assembled value directly. Two substitutions
    happen first, and a reference that skips them does not match the board:

        background_pixel = background_valid and graphical_pixel == 0x00
        palette_index    = background_pixel ? background_data : graphical_pixel
        passthrough      = graphical_pixel == 0xFF

    A passthrough pixel leaves the palette entirely and takes its colour from
    the ordinary Spectrum renderer instead, which is why crisp Spectrum text
    survives on screen while the rest is graphical data. Passthrough pixels are
    returned here as PASSTHROUGH_INDEX so the caller can colour them from the
    ordinary screen.
    """
    base = half * HALF_BYTES
    background = payload[BACKGROUND_OFFSET:BACKGROUND_OFFSET + BACKGROUND_BYTES]
    output = bytearray(PAPER_WIDTH * PAPER_HEIGHT)
    for line in range(PAPER_HEIGHT):
        for byte_column in range(PAPER_WIDTH // 8):
            address = base + spectrum_screen_offset(line, byte_column)
            for pixel_in_byte in range(8):
                source_bit = 7 - pixel_in_byte
                colour = 0
                for lane_index, lane in enumerate(lanes):
                    colour |= ((lane[address] >> source_bit) & 1) << lane_index
                x = byte_column * 8 + pixel_in_byte
                if colour == 0x00 and background:
                    offset = ((BACKGROUND_PAPER_Y + line) * BACKGROUND_WIDTH
                              + BACKGROUND_PAPER_X + x)
                    colour = background[offset]
                output[line * PAPER_WIDTH + x] = colour
    return bytes(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pack", type=Path, help="the .ntsp the board loaded")
    parser.add_argument("output", type=Path, help="reference image to write")
    parser.add_argument(
        "--half", type=int, choices=(0, 1), default=0,
        help="which 8 KiB half of each lane the build displays "
             "(NEXTTANG_SPEC256_ROM_LANE_VIEW_HALF)",
    )
    arguments = parser.parse_args()

    payload = read_pack(arguments.pack)
    indices = render(rom_lanes(payload), arguments.half, payload)
    colours = palette(payload)
    # The ordinary screen is the first 6,912 bytes of main RAM, which the pack
    # loads at 0x4000.
    screen = payload[MAIN_OFFSET:MAIN_OFFSET + BITMAP_BYTES + ATTRIBUTE_BYTES]
    rgb = bytearray()
    for position, index in enumerate(indices):
        if index == PASSTHROUGH_INDEX:
            # The ordinary renderer owns this pixel, exactly as the board's
            # passthrough mux hands it to nexttang_spectrum_display.
            line, x = divmod(position, PAPER_WIDTH)
            rgb.extend(spectrum_pixel_colour(screen, x, line))
        else:
            rgb.extend(colours[index])
    write_ppm_rgb(arguments.output, PAPER_WIDTH, PAPER_HEIGHT, bytes(rgb))
    print(f"wrote {arguments.output} ({PAPER_WIDTH}x{PAPER_HEIGHT}, half {arguments.half})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
