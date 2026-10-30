#!/usr/bin/env python3
"""Write the master's snapshot (.SNA) of a Spec256 .256 game.

The Next loads a Spec256 game from the NextZXOS browser as a snapshot while
the colour data goes over the debug UART (send_next.py), so each .256 needs
its uncoloured twin. A .256 (SPEC256_MISTER's format) holds, for every address
of the eight 16K banks, eight plane bytes and the master's byte, then 28 bytes
of Z80 state:

    AF, AF', I, R, SP, PC, BC, DE, HL, IX, BC', DE', HL', IY (words low byte
    first; I and R as bytes), IFF2 << 3 | IFF1 << 2 | IM, border, port 7FFD

A game with paging locked (7FFD bit 5) is a 48K game and becomes a 49179-byte
48K snapshot; any other becomes a 131103-byte 128K snapshot, which keeps PC and
7FFD in its extension. A 48K snapshot keeps PC on the stack. make256 builds a
.256 from a snapshot with PC at 0x0072, the 48K ROM's RETN, and SP still at the
stacked PC, so that the core starts as a snapshot loader does; such a state
goes back unchanged. Any other PC (a ZX-Poly game) is pushed below SP.

Usage: sna_from_256.py GAME.256 GAME.SNA
"""

from __future__ import annotations

import struct
import sys

BANK = 16_384
MEMORY = 8 * BANK * 9
STATE_AT = MEMORY
RETN_IN_ROM = 0x0072


def master_bank(game: bytes, bank: int) -> bytes:
    base = bank * BANK * 9
    return game[base + 8 : base + BANK * 9 : 9]


def state(game: bytes) -> dict:
    s = game[STATE_AT : STATE_AT + 29]
    words = struct.unpack_from("<HH", s, 0)
    i, r = s[4], s[5]
    sp, pc, bc, de, hl, ix, bc_, de_, hl_, iy = struct.unpack_from("<10H", s, 6)
    flags, border, port_7ffd = s[26], s[27], s[28]
    return dict(af=words[0], af_=words[1], i=i, r=r, sp=sp, pc=pc, bc=bc, de=de,
                hl=hl, ix=ix, bc_=bc_, de_=de_, hl_=hl_, iy=iy,
                iff2=flags >> 3 & 1, iff1=flags >> 2 & 1, im=flags & 3,
                border=border & 7, port_7ffd=port_7ffd)


def header(st: dict, sp: int) -> bytes:
    return (bytes((st["i"],)) +
            struct.pack("<HHHH", st["hl_"], st["de_"], st["bc_"], st["af_"]) +
            struct.pack("<HHHHH", st["hl"], st["de"], st["bc"], st["iy"], st["ix"]) +
            bytes((st["iff2"] << 2, st["r"])) +
            struct.pack("<HH", st["af"], sp) +
            bytes((st["im"], st["border"])))


def snapshot(game: bytes) -> bytes:
    if len(game) < STATE_AT + 29:
        raise ValueError(".256 too short for its Z80 state")
    st = state(game)
    banks = {b: bytearray(master_bank(game, b)) for b in range(8)}
    if st["port_7ffd"] & 0x20:
        memory = banks[5] + banks[2] + banks[0]
        if st["pc"] == RETN_IN_ROM:
            return header(st, st["sp"]) + bytes(memory)
        sp = (st["sp"] - 2) & 0xFFFF
        if sp < 0x4000:
            raise ValueError("SP below 0x4002: PC cannot be pushed into RAM")
        memory[sp - 0x4000 : sp - 0x4000 + 2] = struct.pack("<H", st["pc"])
        return header(st, sp) + bytes(memory)
    current = st["port_7ffd"] & 7
    out = header(st, st["sp"]) + banks[5] + banks[2] + banks[current]
    out += struct.pack("<HBB", st["pc"], st["port_7ffd"], 0)
    for b in range(8):
        if b not in (5, 2, current):
            out += banks[b]
    return bytes(out)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    with open(argv[1], "rb") as f:
        data = snapshot(f.read())
    with open(argv[2], "wb") as f:
        f.write(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
