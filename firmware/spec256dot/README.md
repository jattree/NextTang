# .SPEC256: Spec256 games from the NextZXOS browser

`spec256.asm` is a NextZXOS dot command that loads a Spec256 game's colour
into the NextTang core from a `.256` file on the SD card, with no host and
no UART. The `.256` format is Alberto Conde's (SPEC256_MISTER); the Next reads
the same files, unmodified.

## Card setup

```
scripts/build_spec256_dot.py --output out --palette spec256-palette.pal
```

- `out/SPEC256` goes in `C:/DOT/`.
- `out/SPEC256.RGB` (the palette, 512 bytes, not in this repository) goes
  beside the games, or in `C:/DOT/`.
- Each game needs its `.256` and, for now, its `.sna` beside it.
- Add to `C:/NEXTZXOS/BROWSER.CFG`, before the `Z80,SNA` lines:

```
256:.spec256 "|":clear 65367:load "snapload.bas":f$="|":f$=f$( TO LEN f$-3)+"sna":adj=0:goto 1
256:.spec256 "|":clear 65367:load "snapload.bas":f$="|":f$=f$( TO LEN f$-3)+"sna":adj=1:goto 1
```

Selecting `GAME.256` in the browser then sends its colour and loads
`GAME.sna` through NextZXOS's own snapshot loader; colour starts at the
game's first instruction. A dot command cannot run another, so the browser
line chains the two.

## What it sends

The core's Spec256 loader takes the same command language from the debug
UART or from NextREG writes (see the board top,
`boards/console138k/nexttang_console138k_zxnext.v`):

| NextREG | Write | Read |
|---|---|---|
| 0x3E | one loader byte | 0xA1: interface ID (marker A, version 1) |
| 0x3F | bit 0: the CPU owns the loader; bit 7: abort to idle | status: bit 0 planes mode, 1 inside a payload, 2 armed, 3 colour running, 4 desync, 5 background, 7 CPU owns |

The command sends exactly what `tools/spec256/send_next.py` sends for the
same `.256` and palette (checked byte for byte by `tests/test_spec256_dot.py`
on a Z80 emulator): H, S1, U, C, Y, Z, the planes of banks 5, 2 and 0, the
ROM font, Q, B and G. It refuses a file whose OPT1 asks for a newer core
level than 1, checks the tagged blocks after OPT1, prints the game's CRD1
credits, and on any error aborts the loader, turns colour off and leaves
the CPU speed as it found it.

Not yet: 128K colour beyond banks 5, 2 and 0, the AY state (AYS1), the extra
backgrounds (BGX1), and loading the `.256`'s own memory instead of the
`.sna`.
