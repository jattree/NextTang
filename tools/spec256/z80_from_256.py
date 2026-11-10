#!/usr/bin/env python3
"""Turn a .256's own memory and CPU state into a .z80 (version 3) snapshot.

The .SPEC256 dot command (firmware/spec256dot/spec256.asm) writes the same
file, byte for byte, to /tmp/SPEC256.Z80 on the Next's system drive, and the
browser then starts it with NextZXOS's snapshot loader, so a game needs only
its .256. From the .256 (Alberto Conde's format, SPEC256_MISTER
tools/README.md):

- the master's byte of every address (the ninth of each record): banks 5, 2
  and 0 for a 48K game (7FFD bit 5, paging locked), all eight for a 128K one;
- the 28-byte Z80 state at 1179648 (AF, AF', I, R, SP, PC, BC, DE, HL, IX,
  BC', DE', HL', IY, then IM in bits 0-1 and IFF in bit 2, then the border);
  PC 0x0072 (the ROM's RETN, make256's mark of a snapshot taken in the NMI)
  means the start is on the stack: it is popped, as the RETN would;
- 7FFD at 1179676; AYS1 (21 bytes at 1383028: magic, the selected register,
  R0-R15) when present and not all zero.

The .z80 is version 3 (a 54-byte extended header), pages uncompressed
(length 0xFFFF). Hardware mode 0 (48K, with the AY flag when AYS1 has a
state) or 4 (128K, with 7FFD and the AY). Pages in the order the dot command
reads them: banks 5, 2, 0, then 1, 3, 4, 6, 7.

Usage: z80_from_256.py GAME.256 OUT.z80
"""

from __future__ import annotations

import sys
from pathlib import Path

BANK_BYTES = 16_384
RECORD = 9
STATE_AT = 1_179_648
PORT_7FFD_AT = 1_179_676
AYS1_AT = 1_383_028
AYS1_END = AYS1_AT + 21
NMI_RETN = 0x0072
HEADER_BYTES = 86
EXTRA_HEADER = 54
FIRST_BANKS = (5, 2, 0)
OTHER_BANKS = (1, 3, 4, 6, 7)
PAGE_48K = {5: 8, 2: 4, 0: 5}


def word(data: bytes, at: int) -> int:
    return data[at] | data[at + 1] << 8


def is_48k(game: bytes) -> bool:
    return bool(game[PORT_7FFD_AT] & 0x20)


def master_bank(game: bytes, bank: int) -> bytes:
    start = bank * BANK_BYTES * RECORD + 8
    return game[start:start + BANK_BYTES * RECORD:RECORD]


def ay_state(game: bytes) -> bytes | None:
    """The selected register and R0-R15, or None without an AY state."""
    if len(game) < AYS1_END or game[AYS1_AT:AYS1_AT + 4] != b"AYS1":
        return None
    state = game[AYS1_AT + 4:AYS1_END]
    return state if any(state) else None


def header(game: bytes) -> bytes:
    s = game[STATE_AT:STATE_AT + 28]
    sp, pc = word(s, 6), word(s, 8)
    if pc == NMI_RETN:
        bank_of = {1: 5, 2: 2, 3: game[PORT_7FFD_AT] & 7}

        def master(address: int) -> int:
            slot = address >> 14
            if slot == 0:
                raise ValueError(".256 stack is in the ROM")
            return game[(bank_of[slot] * BANK_BYTES + (address & 0x3FFF)) * RECORD + 8]

        pc = master(sp) | master((sp + 1) & 0xFFFF) << 8
        sp = (sp + 2) & 0xFFFF
    flags, border = s[26], s[27]
    iff = (flags >> 2) & 1
    r = s[5]
    h = bytearray(HEADER_BYTES)
    h[0], h[1] = s[1], s[0]                     # A, F
    h[2:4] = s[10:12]                           # BC
    h[4:6] = s[14:16]                           # HL
    h[8:10] = sp.to_bytes(2, "little")
    h[10] = s[4]                                # I
    h[11] = r & 0x7F
    h[12] = (r >> 7) | (border & 7) << 1
    h[13:15] = s[12:14]                         # DE
    h[15:17] = s[18:20]                         # BC'
    h[17:19] = s[20:22]                         # DE'
    h[19:21] = s[22:24]                         # HL'
    h[21], h[22] = s[3], s[2]                   # A', F'
    h[23:25] = s[24:26]                         # IY
    h[25:27] = s[16:18]                         # IX
    h[27] = h[28] = iff
    h[29] = flags & 3                           # IM
    h[30] = EXTRA_HEADER
    h[32:34] = pc.to_bytes(2, "little")
    ay = ay_state(game)
    if is_48k(game):
        h[34] = 0
        if ay is not None:
            h[37] = 0x04                        # AY in use on a 48K
    else:
        h[34] = 4
        h[35] = game[PORT_7FFD_AT]
    if ay is not None:
        h[38] = ay[0] & 0x0F
        h[39:55] = ay[1:17]
    return bytes(h)


def z80_from_256(game: bytes) -> bytes:
    out = bytearray(header(game))
    banks = FIRST_BANKS if is_48k(game) else FIRST_BANKS + OTHER_BANKS
    for bank in banks:
        page = PAGE_48K[bank] if is_48k(game) else bank + 3
        out += b"\xff\xff" + bytes((page,)) + master_bank(game, bank)
    return bytes(out)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    Path(sys.argv[2]).write_bytes(z80_from_256(Path(sys.argv[1]).read_bytes()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
