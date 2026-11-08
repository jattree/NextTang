#!/usr/bin/env python3
"""Add a BGX2 block to a .256: more than four backgrounds, more than eight rules.

BGX2 is the optional tagged block after OPT1 agreed with Alberto Conde
(llmwiki/raw/alberto-bgx2-agreement-2026-11-02.md): every byte of the file
before it stays as it was, so a player that does not know the tag plays the
game from BGX1 as before. A file ending before OPT1 gets an OPT1 block first
(level 1, no options), as tools for the FLASH option do.

  "BGX2", length (4 bytes, little-endian), then:
    0     E: number of extra backgrounds (1 to 28), numbered 4 to 3+E
    1     R: number of rules (0 to 64)
    2     default background (0 to 3+E, 0xFE none, 0xFF keep the current one)
    3     reserved, 0
    4     E backgrounds, 49152 bytes each (256 x 192 palette indices)
    then  R rules, 64 bytes each, BGX1's layout except byte 0: 0 to 3+E picks
          that background, 0xFE none, 0xFF keep

A background is 49152 bytes as it is, or a 64000-byte Spec256 B00 file (320 x
200), of which the 256 x 192 the Spectrum's paper covers is kept: from column
32, row 4, as make256 keeps it.

A rule is ACTION:CONDITION or ACTION:CONDITION:CONDITION, a condition being
ADDRESS,TEST,MASK,VALUE,START in hexadecimal, TEST being =, !=, < or >= and the
width in bytes, as =1. ADDRESS is RAM bank * 0x4000 + offset, 17 bits. ACTION
is a background number, none or keep.

Usage:
  add_bgx2.py IN.256 OUT.256 --image B03 --image B04 ... \\
      --rule 4:17d1b,=1,ff,0c,19 ... [--default keep]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from send_next import (  # noqa: E402
    BACKGROUND_BYTES,
    BGX2_FIRST_IMAGE,
    BGX2_MAX_EXTRA,
    BGX2_MAX_RULES,
    BGX2_MAX_WATCHES,
    BGX_RULE_BYTES,
    OPT1_AT,
    TAGGED_BLOCKS_AT,
    bgx2_watches,
    game_bgx2,
)

B00_BYTES = 64_000
B00_WIDTH = 320
PAPER_LEFT = 32
PAPER_TOP = 4
PAPER_WIDTH = 256
PAPER_HEIGHT = 192
OPT1_BYTES = TAGGED_BLOCKS_AT - OPT1_AT
OPT1_LEVEL = 1
TESTS = {"=": 1, "!=": 2, "<": 3, ">=": 4}
PICK_NONE = 0xFE
PICK_KEEP = 0xFF


def paper_of(image: bytes) -> bytes:
    """256 x 192 palette indices from a background file."""
    if len(image) == BACKGROUND_BYTES:
        return image
    if len(image) != B00_BYTES:
        raise ValueError(f"a background is {BACKGROUND_BYTES} or {B00_BYTES} bytes, not {len(image)}")
    out = bytearray()
    for row in range(PAPER_TOP, PAPER_TOP + PAPER_HEIGHT):
        at = row * B00_WIDTH + PAPER_LEFT
        out += image[at:at + PAPER_WIDTH]
    return bytes(out)


def pick_code(text: str, extra: int) -> int:
    if text == "none":
        return PICK_NONE
    if text == "keep":
        return PICK_KEEP
    number = int(text, 0)
    if not 0 <= number < BGX2_FIRST_IMAGE + extra:
        raise ValueError(f"background {number} does not exist: 0 to {BGX2_FIRST_IMAGE + extra - 1}")
    return number


def condition_bytes(text: str) -> bytes:
    fields = text.split(",")
    if len(fields) != 5:
        raise ValueError(f"a condition is ADDRESS,TEST,MASK,VALUE,START, not {text!r}")
    address, test, mask, value, start = fields
    kind, width = test[:-1], int(test[-1])
    if kind not in TESTS or not 1 <= width <= 4:
        raise ValueError(f"unknown test {test!r}")
    number = int(address, 16)
    if number >= 1 << 17:
        raise ValueError(f"address {address} is past the 17 bits of a 128K machine's RAM")
    return (number.to_bytes(3, "little") + bytes((TESTS[kind] << 4 | width,))
            + int(mask, 16).to_bytes(4, "little")
            + int(value, 16).to_bytes(4, "little")
            + int(start, 16).to_bytes(4, "little"))


def rule_bytes(text: str, extra: int) -> bytes:
    action, *conditions = text.split(":")
    if not 1 <= len(conditions) <= 2:
        raise ValueError(f"a rule is ACTION:CONDITION[:CONDITION], not {text!r}")
    rule = bytes((pick_code(action, extra), 0)) + b"".join(map(condition_bytes, conditions))
    return rule.ljust(BGX_RULE_BYTES, b"\0")


def add_bgx2(game: bytes, images: list[bytes], rules: list[str], default: str = "keep") -> bytes:
    """The .256 with a BGX2 block at its end, and an OPT1 before it if needed."""
    if not 1 <= len(images) <= BGX2_MAX_EXTRA:
        raise ValueError(f"BGX2 holds 1 to {BGX2_MAX_EXTRA} backgrounds, not {len(images)}")
    if len(rules) > BGX2_MAX_RULES:
        raise ValueError(f"BGX2 holds up to {BGX2_MAX_RULES} rules, not {len(rules)}")
    if len(game) != OPT1_AT and len(game) < TAGGED_BLOCKS_AT:
        raise ValueError(f"the file must reach OPT1 ({OPT1_AT} bytes), not {len(game)}")
    if game_bgx2(game) is not None:
        raise ValueError("the file already has a BGX2 block")
    out = bytearray(game)
    if len(out) == OPT1_AT:
        opt1 = bytearray(OPT1_BYTES)
        opt1[:4] = b"OPT1"
        opt1[4] = OPT1_LEVEL
        out += opt1
    extra = len(images)
    data = bytes((extra, len(rules), pick_code(default, extra), 0))
    data += b"".join(paper_of(image) for image in images)
    table = b"".join(rule_bytes(rule, extra) for rule in rules)
    if bgx2_watches(table) > BGX2_MAX_WATCHES:
        raise ValueError(f"NextTang's core watches up to {BGX2_MAX_WATCHES} different values, "
                         f"these rules need {bgx2_watches(table)}: it would play the file from BGX1")
    data += table
    out += b"BGX2" + len(data).to_bytes(4, "little") + data
    return bytes(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--image", type=Path, action="append", required=True,
                        help="the next extra background, numbered from 4")
    parser.add_argument("--rule", action="append", default=[])
    parser.add_argument("--default", default="keep")
    args = parser.parse_args()
    out = add_bgx2(args.game.read_bytes(), [path.read_bytes() for path in args.image],
                   args.rule, args.default)
    args.output.write_bytes(out)
    print(f"{args.output}: {len(out)} bytes, {len(args.image)} extra backgrounds, {len(args.rule)} rules")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
