# .SPEC256: Spec256 games from the NextZXOS browser

`spec256.asm` is a NextZXOS dot command that loads a Spec256 game into the
NextTang core from its `.256` file on the SD card alone, with no host and no
UART. The `.256` format is Alberto Conde's (SPEC256_MISTER); the Next reads
the same files, unmodified.

## Card setup

```
scripts/build_spec256_dot.py --output out --palette spec256-palette.pal
```

- `out/SPEC256` goes in `C:/DOT/`.
- `out/SPEC256.RGB` (the palette, 512 bytes, not in this repository) goes
  beside the games, or in `C:/DOT/`.
- Each game needs only its `.256`.
- `C:/TMP/` must exist (it does on the standard card); the system drive is
  assumed to be `C:`.
- Add to `C:/NEXTZXOS/BROWSER.CFG`, before the `Z80,SNA` lines (CRLF line
  endings, as the file has; `<7F>` is the single byte 0x7F, which the
  browser replaces with `c:/nextzxos/`, as in the card's own lines):

```
256:.spec256 "|":clear 65367:load "<7F>snapload.bas":f$="c:/tmp/spec256.z80":adj=0:goto 1
256:.spec256 "|":clear 65367:load "<7F>snapload.bas":f$="c:/tmp/spec256.z80":adj=1:goto 1
```

  The first runs on ENTER, the second on SYMBOL SHIFT + ENTER (the snapshot
  loader's options page).

Selecting `GAME.256` in the browser then sends its colour, writes the
game's memory and CPU state as `/tmp/SPEC256.Z80`, and starts that with
NextZXOS's own snapshot loader (which sets up the machine: 48K or 128K
paging, ROM, border, AY); colour starts at the game's first instruction.
The snapshot is a .z80 version 3, exactly what `tools/spec256/z80_from_256.py`
writes: the master's bytes of banks 5, 2 and 0 (48K) or all eight (128K),
the registers (PC 0x0072 means the start is on the stack), 7FFD and the AY
state from AYS1, which an `.sna` cannot carry. A dot command cannot run
another, so the browser line chains the two.

## What it sends

The core's Spec256 loader takes the same command language from the debug
UART or from NextREG writes (see the board top,
`boards/console138k/nexttang_console138k_zxnext.v`):

| NextREG | Write | Read |
|---|---|---|
| 0x3E | one loader byte | 0xA1: interface ID (marker A, version 1); with 0x3F's bit 6 set, the core's level (2: takes L and A), which an older core does not report |
| 0x3F | bit 0: the CPU owns the loader; bit 6: 0x3E reads the level; bit 7: abort to idle | status: bit 0 planes mode, 1 inside a payload, 2 armed, 3 colour running, 4 desync, 5 background, 6 takes E, M and P (BGX1, more backgrounds, other banks), 7 CPU owns |

The command sends exactly what `tools/spec256/send_next.py` sends for the
same `.256` and palette (H, S1, U, C, Y, Z, the planes of banks 5, 2 and 0,
the ROM font, Q, B, then for a BGX1 block E with its rules and M1 to M3 with
each other background that has a pixel, with a BGX2 block L in place of E and
A with each of its backgrounds that has a pixel, and G) and writes exactly the snapshot `z80_from_256.py`
writes. Both are checked byte for byte by `tests/test_spec256_dot.py` on a
Z80 emulator, and the snapshot writer was checked against SkoolKit's .z80
reader for all 43 games. It refuses a file whose OPT1 asks for a newer core
level than 1, checks the tagged blocks after OPT1, prints the game's CRD1
credits, and on any error aborts the loader, turns colour off and leaves
the CPU speed as it found it.

It sends E, M and P only when NextREG 0x3F reads with bit 6 set, so it
loads games safely, without those, on a core older than them. It sends L and
A only to a core that reads level 2 or above; an older one plays the same file
from BGX1, as a player that does not know the tag does.

The core keeps the backgrounds in DDR3 and applies BGX1's rules as
SPEC256_MISTER does: once a frame the first rule whose conditions hold picks
the background (4: none; 255: keep the current one), and the picked one is
copied into the overlay during the border.

BGX2, the optional tagged block after OPT1 agreed with Alberto Conde, takes this
to 32 backgrounds (28 extra, numbered from 4) and 64 rules, with 0xFE for none
and 0xFF for keep. BGX2's rules replace BGX1's; BGX1's backgrounds stay as 1 to
3. A malformed block is skipped like an unknown tag, and so is one needing more
than the core's 16 different watched values (an address, width and starting
value), so that file plays from BGX1. `tools/spec256/add_bgx2.py`
adds one to a `.256`, leaving every existing byte as it was.

Not yet: 128K colour beyond banks 5, 2 and 0.
