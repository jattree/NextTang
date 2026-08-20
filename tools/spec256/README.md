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

The mapping and renderer are covered by `tests/test_spec256_gfx.py` and
`tests/test_spec256_render.py`.

The compatibility reference is
[GZX commit `7b31e6d`](https://github.com/jxsvoboda/gzx/commit/7b31e6d11ead86ed5de8cba07d0df0870dd7e450).
The original format and graphical-processor model are described by the
[archived Spec256 documentation](https://web.archive.org/web/20070418181853/http://emulatronia.com/emusdaqui/spec256/comofunciona-eng.htm).
These tools are a clean implementation of the observed data mapping; no GZX
source or game asset is included.
