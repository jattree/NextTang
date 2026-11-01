#!/usr/bin/env python3
"""Load a Spec256 game's colour data into the Next core over the debug UART.

The board's Spec256 loader (rtl/input/nexttang_spec256_uart_loader.v) takes:
S1 to turn the Layer 2 mirror into the colour planes, U with the game's rules
flags, W with the plane words for 0x4000 to 0xFFFF, Q with the 256-entry
RGB333 palette, and G with the address of the game's first instruction, where
colour mode begins. The game itself is loaded on the Next as usual (its .SNA
from the NextZXOS browser, at 3.5 MHz); arm before loading it.

The planes come from a Spec256 GFX, or from a .256 built by Alberto Conde's
make256 (SPEC256_MISTER), which also carries the game's corrections (such as
Jetpac's rocket taking the attribute ink), its RUL1 flags and, when it has
one, its coloured ROM character set (GRX1, 0x3D00 to 0x3FFF), sent as plane
words from 0x3D00. Only the 48K banks are sent: 5, 2 and 0 at 0x4000, 0x8000
and 0xC000. H goes first, so a previous game's font and background are
dropped. A .256's background (256 x 192 palette indices, 0 for none) goes
with B when it has any pixel, its .CFG colours with C, and RUL1's eight
per-plane read rules with Y. A 128K game's banks 1, 3, 4, 6 and 7 that carry
colour go with P (the bank) and W at 0xC000 each, then P0. With a BGX1 block, E sends its header's count,
rule count, default and reserved byte and its eight rules, which pick the
background shown, and M1 to M3 its other backgrounds, each that has a pixel.

Without --palette a test palette is sent, the index's bits spread over RGB333,
enough to see whether the planes land in the right places.

Usage:
  send_next.py (--gfx GAME.GFX | --game GAME.256) --snapshot GAME.SNA
               [--palette sp256.pal] [--port DEV]
"""

from __future__ import annotations

import argparse
import os
import sys
import termios
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gfx import GFX_SIZE, decode_gfx, read_exact_file  # noqa: E402
from render import load_palette  # noqa: E402
from snapshot import parse_snapshot  # noqa: E402

PORT = "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A5069RR4-if00-port0"
BAUD_BYTES_PER_SECOND = 11_520

# The .256 layout (SPEC256_MISTER tools/README.md, "The .256 format"): every
# address of the eight 16K banks as eight plane bytes, plane 0 first, then
# the master's byte; RUL1 is 72 bytes at RUL1_AT, its flags at +5.
BANK_BYTES = 16_384 * 9
GAME_MIN_SIZE = 8 * BANK_BYTES
RUL1_AT = 1_382_956
GRX1_AT = 1_376_808
CFG_AT = 1_179_677
BACKGROUND_AT = 1_179_680
BACKGROUND_BYTES = 256 * 192
BGX1_AT = BACKGROUND_AT + BACKGROUND_BYTES
BGX1_IMAGES_AT = BGX1_AT + 8
BGX1_RULES_AT = BGX1_IMAGES_AT + 3 * BACKGROUND_BYTES
BGX1_END = BGX1_RULES_AT + 8 * 64
ROM_FONT_START = 0x3D00
ROM_FONT_WORDS = 768
SPECTRUM_48K_BANKS = (5, 2, 0)


def plane_words(gfx: bytes) -> bytes:
    """Every Spectrum address from 0x4000, eight bytes: plane 0's first."""
    planes = decode_gfx(gfx)
    out = bytearray()
    for address in range(len(planes[0])):
        out += bytes(plane[address] for plane in planes)
    return bytes(out)


def game_plane_words(game: bytes) -> bytes:
    """Plane words for 0x4000 to 0xFFFF from a .256, as plane_words gives them."""
    if len(game) < GAME_MIN_SIZE:
        raise ValueError(f".256 must be at least {GAME_MIN_SIZE} bytes, got {len(game)}")
    out = bytearray()
    for bank in SPECTRUM_48K_BANKS:
        for offset in range(16_384):
            at = bank * BANK_BYTES + offset * 9
            out += game[at : at + 8]
    return bytes(out)


def game_rom_font_words(game: bytes) -> bytes | None:
    """GRX1's plane words for 0x3D00 to 0x3FFF, or None without the block."""
    if game[GRX1_AT : GRX1_AT + 4] != b"GRX1":
        return None
    words = game[GRX1_AT + 4 : GRX1_AT + 4 + ROM_FONT_WORDS * 8]
    if len(words) != ROM_FONT_WORDS * 8:
        raise ValueError(".256 ends inside its GRX1 block")
    return words


def game_background(game: bytes) -> bytes | None:
    """The main background, or None when it is all 0 (no background)."""
    background = game[BACKGROUND_AT : BACKGROUND_AT + BACKGROUND_BYTES]
    if len(background) != BACKGROUND_BYTES or not any(background):
        return None
    return background


def game_bgx(game: bytes) -> bytes | None:
    """E's 516 bytes: BGX1's count, rule count, default, reserved, rules."""
    if len(game) < BGX1_END or game[BGX1_AT:BGX1_AT + 4] != b"BGX1":
        return None
    return game[BGX1_AT + 4:BGX1_AT + 8] + game[BGX1_RULES_AT:BGX1_END]


def game_extra_backgrounds(game: bytes) -> list[tuple[int, bytes]]:
    """BGX1's backgrounds 1 to 3 that have a pixel, with their numbers."""
    if game_bgx(game) is None:
        return []
    images = []
    for number in range(1, 4):
        at = BGX1_IMAGES_AT + (number - 1) * BACKGROUND_BYTES
        image = game[at:at + BACKGROUND_BYTES]
        if any(image):
            images.append((number, image))
    return images


OTHER_128K_BANKS = (1, 3, 4, 6, 7)


def game_other_banks(game: bytes) -> list[tuple[int, bytes]]:
    """A 128K game's plane words for banks 1, 3, 4, 6 and 7, each bank with
    any record whose planes are not its master's byte eight times (the rest
    read as the board shows a bank without planes)."""
    if game[PORT_7FFD_AT] & 0x20:
        return []
    banks = []
    for bank in OTHER_128K_BANKS:
        words = bytearray()
        coloured = False
        for offset in range(16_384):
            at = bank * BANK_BYTES + offset * 9
            record = game[at : at + 9]
            words += record[:8]
            coloured = coloured or record[:8] != bytes((record[8],)) * 8
        if coloured:
            banks.append((bank, bytes(words)))
    return banks


def game_cfg(game: bytes) -> bytes:
    """UpColorsMixed, DownColorsMixed and the CFG flags."""
    return game[CFG_AT : CFG_AT + 3]


def game_rules(game: bytes) -> bytes | None:
    """RUL1's eight 8-byte rules, or None without RUL1 version 1 or rules."""
    if game[RUL1_AT : RUL1_AT + 4] != b"RUL1" or game[RUL1_AT + 4] != 1:
        return None
    if game[RUL1_AT + 6] == 0:
        return None
    return game[RUL1_AT + 8 : RUL1_AT + 72]


def game_zxpoly_mode(game: bytes) -> int:
    """RUL1 byte 7: the ZX-Poly video mode (4, 6 or 7), or 0."""
    if game[RUL1_AT : RUL1_AT + 4] != b"RUL1" or game[RUL1_AT + 4] != 1:
        return 0
    return game[RUL1_AT + 7] & 7


OPT1_AT = 1_383_117
OPT1_SIZE = 256


def game_options(game: bytes) -> int:
    """OPT1 byte 8, the options agreed with Alberto Conde (bit 0: FLASH cells
    show the Spectrum's pixel in the on phase), or 0 without a whole OPT1."""
    if len(game) < OPT1_AT + OPT1_SIZE or game[OPT1_AT : OPT1_AT + 4] != b"OPT1":
        return 0
    return game[OPT1_AT + 8]


def game_rules_flags(game: bytes) -> int:
    """RUL1's flags (bit 0: DOS render), or 0 for a .256 without RUL1."""
    if game[RUL1_AT : RUL1_AT + 4] != b"RUL1" or game[RUL1_AT + 4] != 1:
        return 0
    return game[RUL1_AT + 5]


REGISTERS_AT = 1_179_648
PORT_7FFD_AT = 1_179_676
NMI_RETN = 0x0072


def game_start_pc(game: bytes) -> int:
    """The game's first instruction from the .256 itself: its PC or, when
    make256 stored the ROM's RETN at 0x0072 (a snapshot taken in the NMI),
    the address on its stack, read from the master's bytes with the
    snapshot's 128K paging. firmware/spec256dot/spec256.asm does the same."""
    pc = game[REGISTERS_AT + 8] | game[REGISTERS_AT + 9] << 8
    if pc != NMI_RETN:
        return pc
    sp = game[REGISTERS_AT + 6] | game[REGISTERS_AT + 7] << 8

    def master(address: int) -> int:
        slot = address >> 14
        if slot == 0:
            raise ValueError(".256 stack is in the ROM")
        bank = (5, 2, game[PORT_7FFD_AT] & 7)[slot - 1]
        return game[(bank * 16_384 + (address & 0x3FFF)) * 9 + 8]

    return master(sp) | master((sp + 1) & 0xFFFF) << 8


def colour_stream(words: bytes, flags: int, cfg: bytes, rules: bytes | None, zxpoly: int,
                  font: bytes | None, background: bytes | None, palette: bytes, pc: int,
                  bgx: bytes | None = None,
                  extra_backgrounds: list[tuple[int, bytes]] | None = None,
                  other_banks: list[tuple[int, bytes]] | None = None,
                  options: int = 0) -> bytes:
    """The loader's commands for one game, in the order it takes them. O (the
    OPT1 options) only when non-zero, so other games' streams are unchanged."""
    out = b"H" + b"S1" + b"U%02x" % flags + b"C" + cfg.hex().encode()
    if rules is not None:
        out += b"Y" + rules
    out += b"Z%d" % zxpoly
    if options:
        out += b"O%02x" % options
    out += b"W4000%04x" % (len(words) // 8) + words
    if font is not None:
        out += b"W%04x%04x" % (ROM_FONT_START, ROM_FONT_WORDS) + font
    out += b"Q" + palette
    if background is not None:
        out += b"B" + background
    if bgx is not None:
        out += b"E" + bgx
        for number, image in extra_backgrounds or []:
            out += b"M%d" % number + image
    if other_banks is not None:
        for bank, bank_words in other_banks:
            out += b"P%d" % bank + b"Wc000%04x" % (len(bank_words) // 8) + bank_words
        out += b"P0"
    return out + b"G%04x" % pc


def game_colour_stream(game: bytes, palette: bytes, pc: int | None = None,
                       extended: bool = True) -> bytes:
    """colour_stream for a .256; the start from the .256 unless given. Without
    extended (a core whose NextREG 0x3F bit 6 is clear) E, M and P are left
    out, as .SPEC256 leaves them out for it."""
    return colour_stream(game_plane_words(game), game_rules_flags(game), game_cfg(game),
                         game_rules(game), game_zxpoly_mode(game), game_rom_font_words(game),
                         game_background(game), palette,
                         game_start_pc(game) if pc is None else pc,
                         game_bgx(game) if extended else None,
                         game_extra_backgrounds(game) if extended else None,
                         None if game[PORT_7FFD_AT] & 0x20 or not extended else game_other_banks(game),
                         game_options(game))


SNA_128K_SIZE = 131_103


def snapshot_pc(data: bytes) -> int:
    """The PC a snapshot resumes at: stacked in a 48K SNA, stored after the
    first 48K in a 128K SNA's extension."""
    if len(data) == SNA_128K_SIZE:
        return data[49_179] | data[49_180] << 8
    return parse_snapshot(data).pc


def rgb333(red: int, green: int, blue: int) -> int:
    return (red >> 5) << 6 | (green >> 5) << 3 | (blue >> 5)


def palette_bytes(path: Path | None) -> bytes:
    if path is None:
        entries = [((i >> 5) & 7) << 6 | ((i >> 2) & 7) << 3 | ((i & 3) << 1 | (i & 1))
                   for i in range(256)]
    else:
        entries = [rgb333(*colour) for colour in load_palette(path)]
    return b"".join(bytes((e & 0xFF, e >> 8)) for e in entries)


def send(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        try:
            written = os.write(fd, view)
        except BlockingIOError:
            time.sleep(0.01)
            continue
        view = view[written:]
        # Keep the kernel's queue short; the UART runs at 115200.
        time.sleep(written / BAUD_BYTES_PER_SECOND)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--gfx", type=Path)
    source.add_argument("--game", type=Path, help="a .256 built by make256")
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--palette", type=Path)
    parser.add_argument("--port", default=PORT)
    args = parser.parse_args()

    if args.game is not None:
        game = args.game.read_bytes()
        words = game_plane_words(game)
        flags = game_rules_flags(game)
        font = game_rom_font_words(game)
        background = game_background(game)
        cfg = game_cfg(game)
        rules = game_rules(game)
        zxpoly = game_zxpoly_mode(game)
        bgx = game_bgx(game)
        extra = game_extra_backgrounds(game)
        other = None if game[PORT_7FFD_AT] & 0x20 else game_other_banks(game)
    else:
        words = plane_words(read_exact_file(args.gfx, GFX_SIZE, "Spec256 GFX"))
        flags = 0
        font = None
        background = None
        cfg = bytes(3)
        rules = None
        zxpoly = 0
        bgx = None
        extra = []
        other = None
    palette = palette_bytes(args.palette)
    pc = snapshot_pc(args.snapshot.read_bytes())
    count = len(words) // 8

    fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    started = time.time()
    send(fd, colour_stream(words, flags, cfg, rules, zxpoly, font, background, palette, pc,
                           bgx, extra, other))
    time.sleep(0.2)
    os.close(fd)
    print(f"sent {count} plane words, palette ({'test' if args.palette is None else args.palette.name}), "
          f"rules flags 0x{flags:02x}, CFG {cfg.hex()}, {'ROM font, ' if font is not None else ''}"
          f"{'background, ' if background is not None else ''}"
          f"{'rules, ' if rules is not None else ''}"
          f"{f'BGX1 rules and {len(extra)} more backgrounds, ' if bgx is not None else ''}"
          f"armed at PC 0x{pc:04x}, "
          f"{time.time() - started:.0f} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
