#!/usr/bin/env python3
"""Apply a text patch (a translation) to a Spec256 .256, or turn it into IPS.

A .256 holds every address of a 128K Spectrum's memory as nine bytes, eight
colour planes and then the game's own byte. A text patch changes only the
game's own bytes of the text it names, so the colours, which belong to the
font's shapes, stay as they were. Each English string replaces a Spanish one
of exactly the same length: the games print strings inline after a CALL and
carry on after the terminator, so a string may not grow or shrink (pad with
spaces).

Patch file (UTF-8 text, one rule per line, # starts a comment):

  game: Army Moves (Part 1)
  sha256: <the .256 this patch is for>
  "1-TECLADO" = "1-KEYS   "
  "IZQUIERDA  SUBIR" = "LEFT       UP   " x2

A rule replaces every occurrence of the left string in the game's bytes, and
there must be exactly as many as it says (x1 when not given). The input must
match the sha256, so a patch never lands on a different version of a game.
The original file is never changed.

Usage:
  patch256.py PATCH GAME.256 OUT.256      write the patched .256
  patch256.py PATCH GAME.256 --ips OUT.ips  write an IPS patch instead
  patch256.py PATCH GAME.256 --check      only check that it applies
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

BANKS = 8
BANK_BYTES = 16_384
RECORD = 9
RULE = re.compile(r'^"(.*)"\s*=\s*"(.*)"\s*(?:x(\d+))?$')


class PatchError(Exception):
    pass


def read_patch(text: str) -> tuple[dict[str, str], list[tuple[bytes, bytes, int]]]:
    header: dict[str, str] = {}
    rules: list[tuple[bytes, bytes, int]] = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = RULE.match(line)
        if match:
            old, new, count = match.group(1), match.group(2), int(match.group(3) or 1)
            if len(old) != len(new):
                raise PatchError(f"line {number}: {old!r} is {len(old)} characters, {new!r} is {len(new)}")
            if not old or not all(32 <= ord(c) < 127 for c in old + new):
                raise PatchError(f"line {number}: strings must be printable ASCII")
            rules.append((old.encode(), new.encode(), count))
        elif ":" in line:
            key, _, value = line.partition(":")
            header[key.strip()] = value.strip()
        else:
            raise PatchError(f"line {number}: not a rule or a header: {raw!r}")
    return header, rules


def game_bytes(game: bytes) -> bytes:
    """The game's own byte of every address, bank 0 first."""
    return game[RECORD - 1 : BANKS * BANK_BYTES * RECORD : RECORD]


def changes(game: bytes, patch_text: str) -> dict[int, int]:
    """File offset -> new byte for every byte the patch changes."""
    header, rules = read_patch(patch_text)
    if len(game) < BANKS * BANK_BYTES * RECORD:
        raise PatchError("not a .256: too short")
    wanted = header.get("sha256")
    if wanted is None:
        raise PatchError("the patch names no sha256")
    actual = hashlib.sha256(game).hexdigest()
    if actual != wanted.lower():
        raise PatchError(f"this .256 is not the one the patch is for (sha256 {actual})")
    memory = game_bytes(game)
    out: dict[int, int] = {}
    for old, new, count in rules:
        found = []
        start = 0
        while (at := memory.find(old, start)) >= 0:
            # A string never runs from one bank into the next.
            if at // BANK_BYTES == (at + len(old) - 1) // BANK_BYTES:
                found.append(at)
            start = at + 1
        if len(found) != count:
            raise PatchError(f"{old.decode()!r}: found {len(found)} times, the patch expects {count}")
        for at in found:
            for i, byte in enumerate(new):
                offset = (at + i) * RECORD + RECORD - 1
                if out.get(offset, byte) != byte:
                    raise PatchError(f"{old.decode()!r} overlaps another rule")
                out[offset] = byte
    return out


def apply(game: bytes, patch_text: str) -> bytes:
    patched = bytearray(game)
    for offset, byte in changes(game, patch_text).items():
        patched[offset] = byte
    return bytes(patched)


def ips(game: bytes, patch_text: str) -> bytes:
    """An IPS patch with one record per run of consecutive changed bytes."""
    out = bytearray(b"PATCH")
    edits = sorted(changes(game, patch_text).items())
    i = 0
    while i < len(edits):
        start = edits[i][0]
        run = bytearray([edits[i][1]])
        while i + 1 < len(edits) and edits[i + 1][0] == start + len(run) and len(run) < 0xFFFF:
            i += 1
            run.append(edits[i][1])
        if start == 0x454F46:  # "EOF" as an offset would end the patch early
            start -= 1
            run.insert(0, game[start])
        out += start.to_bytes(3, "big") + len(run).to_bytes(2, "big") + run
        i += 1
    return bytes(out + b"EOF")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("patch", type=Path)
    parser.add_argument("game", type=Path)
    parser.add_argument("out", type=Path, nargs="?")
    parser.add_argument("--ips", type=Path, help="write an IPS patch instead of a .256")
    parser.add_argument("--check", action="store_true", help="only check that the patch applies")
    args = parser.parse_args()
    patch_text = args.patch.read_text(encoding="utf-8")
    game = args.game.read_bytes()
    try:
        if args.check:
            print(f"{len(changes(game, patch_text))} bytes would change")
        elif args.ips is not None:
            args.ips.write_bytes(ips(game, patch_text))
            print(f"wrote {args.ips}")
        elif args.out is not None:
            if args.out.resolve() == args.game.resolve():
                raise PatchError("write the patched game to a new file, not over the original")
            args.out.write_bytes(apply(game, patch_text))
            print(f"wrote {args.out}")
        else:
            parser.error("give OUT.256, --ips OUT.ips or --check")
    except PatchError as error:
        print(f"patch256: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
