# Spec256 reference tools

This directory contains clean conformance helpers for the original 48K
Spec256 format. It does not contain a Spectrum ROM, snapshots, GFX files,
backgrounds, palettes or the original DOS executable.

Inspect a user-supplied GFX file:

```sh
python3 tools/spec256/gfx.py /absolute/path/to/GAME.GFX
```

The command validates the original 393,216-byte layout, transposes it into the
eight 48 KiB planes used by the open GZX implementation, prints stable hashes
and verifies that encoding the planes again reproduces the input byte for
byte.

Render the 256x192 paper using user-supplied graphics, background and palette:

```sh
python3 tools/spec256/render.py /absolute/path/to/GAME.GFX \
  --background /absolute/path/to/GAME.B00 \
  --palette /absolute/path/to/sp256.pal \
  --output /tmp/game.ppm
```

For an FPGA build, emit one RGB332 byte per paper pixel without committing the
generated image:

```sh
python3 tools/spec256/render.py /absolute/path/to/GAME.GFX \
  --background /absolute/path/to/GAME.B00 \
  --palette /absolute/path/to/sp256.pal \
  --output-format rgb332-mem \
  --output /tmp/game-rgb332.mem
```

The mapping and renderer are covered by `tests/test_spec256_gfx.py` and
`tests/test_spec256_render.py`.

The compatibility reference is
[GZX commit `7b31e6d`](https://github.com/jxsvoboda/gzx/commit/7b31e6d11ead86ed5de8cba07d0df0870dd7e450).
The original format and graphical-processor model are described by the
[archived Spec256 documentation](https://web.archive.org/web/20070418181853/http://emulatronia.com/emusdaqui/spec256/comofunciona-eng.htm).
These tools are a clean implementation of the observed data mapping; no GZX
source or game asset is included.

Generate the first asset-free instruction fixture:

```sh
python3 tools/spec256/conformance.py /tmp/spec256-conformance
```

`LD_COPY.SNA` runs `LD A,(0x9000)`, `LD (0x4000),A`, then halts. Its GFX file
gives the source byte a different value in each graphical plane. A compatible
graphical processor should leave paper pixels with palette indices 1, 2, 4, 8,
16, 32, 64 and 128. Generated SNA and GFX files are test artifacts and must not
be committed.

The RTL follows the pinned GZX execution model: graphical lanes use the
master's instruction stream and effective addresses while retaining their own
plane data and data-register values. `build_master_address_fixture()` provides
the focused `LD HL,(nn)` / `LD (HL),n` discriminator used by the regression
suite.

Build a private runtime pack from user-supplied assets:

```sh
python3 tools/spec256/gamepack.py \
  --snapshot /absolute/path/to/GAME.SNA \
  --gfx /absolute/path/to/GAME.GFX \
  --rom-gfx /absolute/path/to/GAME.GFB \
  --palette /absolute/path/to/sp256.pal \
  --output /tmp/GAME.ntsp
```

When a conversion has no graphical ROM, omit `--rom-gfx` and pass the ordinary
16 KiB Spectrum ROM with `--rom`. The pack builder clones that ROM into all
eight graphical execution planes, matching GZX initialization. It never embeds
a ROM unless the user explicitly supplies it, and generated packs remain
private build artifacts.
