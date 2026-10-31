#!/usr/bin/env python3
"""Apply a text patch (a translation) to a Spec256 .256, or turn it into IPS.

A .256 holds every address of a 128K Spectrum's memory as nine bytes, eight
colour planes and then the game's own byte. Spec256's colour CPUs read a
string's characters from their own planes, so in a game's text all nine
bytes of a character hold the same code; a text patch changes all nine, and
refuses a character whose planes say anything else (colour data, not text).
The colours of the printed letters belong to the font's shapes and stay as
they were. Each English string replaces a Spanish one
of exactly the same length: the games print strings inline after a CALL and
carry on after the terminator, so a string may not grow or shrink (pad with
spaces).

Patch file (UTF-8 text, one rule per line, # starts a comment):

  game: Army Moves (Part 1)
  sha256: <the .256 this patch is for>
  "1-TECLADO" = "1-KEYS   "
  "IZQUIERDA  SUBIR" = "LEFT       UP   " x2

A rule replaces every occurrence of the left string in the game's bytes, and
there must be exactly as many as it says (x1 when not given).

A game whose snapshot was taken with a menu already on screen keeps showing
the old text until it prints the menu again. With "redraw: N" the patch
prints it again itself: for a string printed inline after a CALL, the N
bytes before it being the code that places and prints it, the tool runs that
code on a Z80 emulator (the z80 package) with the original text and, only if
the pixels stay as they are but for a mark or two (that text is on screen,
perhaps with a menu's selection mark over it), again with the new text, once
on the game's bytes and once on each colour plane, as Spec256's nine CPUs
would, and writes the pixel bytes that change, leaving the marks and the
attributes as they were. "redraw-run: START END" (hex) does the same for a
block of the game's code that prints a whole screen of text, such as a
menu printed from a table. Games
print through the Spectrum ROM, so this needs a 48K ROM image (--rom) and
`pip install z80`; the .ips files have it done already. The input must
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


REGISTERS_AT = 8 * BANK_BYTES * RECORD   # the CPU state, after the banks
SCREEN = range(0x4000, 0x5800)   # the pixels; attributes are left alone
MARKS = 24                        # pixel bytes that may differ: a mark or two


def layer_memory(game: bytes, layer: int, rom: bytes) -> bytearray:
    """64K as one of the nine CPUs sees it (layer 8: the game's own bytes):
    the ROM, then banks 5, 2 and the one 7FFD pages at 0xC000."""
    memory = bytearray(rom[:0x4000]) + bytearray(0xC000)
    for base, bank in ((0x4000, 5), (0x8000, 2), (0xC000, game[REGISTERS_AT + 28] & 7)):
        start = bank * BANK_BYTES * RECORD + layer
        memory[base:base + BANK_BYTES] = game[start:start + BANK_BYTES * RECORD:RECORD]
    return memory


def run_print(memory: bytearray, game: bytes, start: int, end: int) -> bytes | None:
    """Run memory's code from start to end with the snapshot's registers and
    interrupts off; the screen afterwards, or None if it never got there."""
    import z80  # noqa: PLC0415 (optional)
    import struct  # noqa: PLC0415

    machine = z80.Z80Machine()
    machine.set_memory_block(0, bytes(memory))
    regs = game[REGISTERS_AT:REGISTERS_AT + 32]
    sp, _pc, bc, de, hl, ix, _bc2, _de2, _hl2, iy = struct.unpack_from("<10H", regs, 6)
    machine.af = struct.unpack_from("<H", regs, 0)[0]
    machine.bc, machine.de, machine.hl, machine.ix, machine.iy, machine.sp = bc, de, hl, ix, iy, sp
    machine.iff1 = machine.iff2 = 0
    machine.pc = start
    machine.set_breakpoint(end)
    for _ in range(200):
        machine.ticks_to_stop = 100_000
        machine.run()
        if machine.pc == end:
            return bytes(machine.memory[SCREEN.start:SCREEN.stop])
    return None


def redraw(game: bytes, patched: bytes, occurrences: list[tuple[int, bytes, bytes]],
           setup: int | None, runs: list[tuple[int, int]], rom: bytes | None) -> dict[int, int]:
    """Screen bytes, by file offset, of the text on screen printed anew: each
    inline string after its setup code, and each block of code in runs."""
    try:
        import z80  # noqa: F401, PLC0415
    except ImportError as error:
        raise PatchError("this patch redraws the screen: pip install z80") from error
    if rom is None or len(rom) < 0x4000:
        raise PatchError("this patch redraws the screen, which needs a 48K ROM image: --rom 48.rom")
    out: dict[int, int] = {}
    original = layer_memory(game, RECORD - 1, rom)
    screen = bytes(original[SCREEN.start:SCREEN.stop])
    blocks: list[tuple[int, int, str]] = list((start, end, f"{start:04x}") for start, end in runs)
    for at, old, _new in occurrences if setup is not None else []:
        address = {5: 0x4000, 2: 0x8000}.get(at // BANK_BYTES)
        if address is None:
            if at // BANK_BYTES != game[REGISTERS_AT + 28] & 7:
                continue
            address = 0xC000
        address += at % BANK_BYTES
        if original[address - 3] == 0xCD:
            blocks.append((address - setup, address + len(old) + 1, old.decode()))
    for start, end, name in blocks:
        printed = run_print(original, game, start, end)
        if printed is None:
            continue
        marks = {i for i, (a, b) in enumerate(zip(printed, screen)) if a != b}
        if len(marks) > MARKS:
            continue
        for layer in range(RECORD):
            memory = layer_memory(patched, layer, rom)
            after = run_print(memory, patched, start, end)
            if after is None:
                raise PatchError(f"{name!r}: printing the new text did not finish")
            for i, byte in enumerate(after):
                if i not in marks and byte != memory[SCREEN.start + i]:
                    out[(5 * BANK_BYTES + SCREEN.start + i - 0x4000) * RECORD + layer] = byte
    return out


def changes(game: bytes, patch_text: str, rom: bytes | None = None) -> dict[int, int]:
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
    occurrences: list[tuple[int, bytes, bytes]] = []
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
            occurrences.append((at, old, new))
            for i, byte in enumerate(new):
                record = (at + i) * RECORD
                if game[record:record + RECORD] != bytes((old[i],)) * RECORD:
                    raise PatchError(f"{old.decode()!r}: the planes of character {i} are not "
                                     "its code eight times, so this is not plain text")
                for offset in range(record, record + RECORD):
                    if out.get(offset, byte) != byte:
                        raise PatchError(f"{old.decode()!r} overlaps another rule")
                    out[offset] = byte
    if "redraw" in header or "redraw-run" in header:
        patched = bytearray(game)
        for offset, byte in out.items():
            patched[offset] = byte
        setup = int(header["redraw"]) if "redraw" in header else None
        numbers = [int(n, 16) for n in header.get("redraw-run", "").split()]
        runs = list(zip(numbers[0::2], numbers[1::2]))
        out.update(redraw(game, bytes(patched), occurrences, setup, runs, rom))
    return out


def apply(game: bytes, patch_text: str, rom: bytes | None = None) -> bytes:
    patched = bytearray(game)
    for offset, byte in changes(game, patch_text, rom).items():
        patched[offset] = byte
    return bytes(patched)


def ips(game: bytes, patch_text: str, rom: bytes | None = None) -> bytes:
    """An IPS patch with one record per run of consecutive changed bytes."""
    out = bytearray(b"PATCH")
    edits = sorted(changes(game, patch_text, rom).items())
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
    parser.add_argument("--rom", type=Path, help="48K Spectrum ROM image, for patches that redraw the screen")
    args = parser.parse_args()
    patch_text = args.patch.read_text(encoding="utf-8")
    game = args.game.read_bytes()
    rom = args.rom.read_bytes() if args.rom is not None else None
    try:
        if args.check:
            print(f"{len(changes(game, patch_text, rom))} bytes would change")
        elif args.ips is not None:
            args.ips.write_bytes(ips(game, patch_text, rom))
            print(f"wrote {args.ips}")
        elif args.out is not None:
            if args.out.resolve() == args.game.resolve():
                raise PatchError("write the patched game to a new file, not over the original")
            args.out.write_bytes(apply(game, patch_text, rom))
            print(f"wrote {args.out}")
        else:
            parser.error("give OUT.256, --ips OUT.ips or --check")
    except PatchError as error:
        print(f"patch256: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
