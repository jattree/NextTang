# Upstream provenance and import policy

NextTang has selected the MiSTer ZXNext repository at commit
[`1c7db8649193c109ea292d82d1f729d22eb1f5e7`](https://github.com/MiSTer-devel/ZXNext_MISTer/commit/1c7db8649193c109ea292d82d1f729d22eb1f5e7)
(`Release 20260603`) as the baseline for the first port. Its Git tree is
`e2febf8f495714629a279693ce2d9dd7d2d757ab`.

The first import from that repository landed on 2026-08-18: the five T80 CPU
family files under `rtl/cpu/`. The second imports `rtl/video/zxula.vhd` and
`rtl/video/zxula_timing.vhd` for the native machine raster. All seven files were
taken byte-identical from the pinned commit and verified against the Git blob
hashes recorded in [the per-file audit](upstream-files.tsv). Their notices are
retained unmodified in the sources, and `THIRD_PARTY_NOTICES.md` must accompany
any synthesized artifact built from them.

The CPU files have run on the Console 138K in the hardware-verified 48K image.
The two ULA files first passed separate exact-device synthesis probes and now
also run in the separate hardware-verified `ula` profile. That image reads the
48K display file, captures each complete 360 x 288 native frame and presents a
2x 720 x 576 image inside the established 720p60 output. This does not yet
connect upstream ULA timing to CPU contention or interrupt timing, and does not
verify ULANext, ULA+, LoRes or the other Next display layers.

One line of `rtl/cpu/t80n.vhd` is modified from the pinned commit. Upstream
writes `ioq := (ioq and x"7")`, masking a nine-bit variable with a four-bit
literal, which Gowin rejects as a width mismatch. It is changed to
`(ioq and "000000111")`, which preserves the behaviour every other toolchain
gives that line. The modification is recorded here because the file is otherwise
byte-identical and its blob hash therefore no longer matches the audit.

The third import, on 2026-10-26, brings in the rest of the machine core:
`rtl/zxnext.vhd` and the 28 files it instantiates under `rtl/audio/`,
`rtl/device/`, `rtl/misc/`, `rtl/serial/` and `rtl/video/`. That set is the
transitive closure of `zxnext.vhd`, less three files:

- `rtl/rom/bootrom.vhd`, which stays excluded and is replaced by the
  project-owned `rtl/core/nexttang_diagnostic_bootrom.vhd`.
- MiSTer's `rtl/mister/bram.vhd`, which is replaced by the inferred RAMs under
  `rtl/core/memory/`.
- `rtl/serial/uart_old.vhd`, which redefines the `uart` entity and is not in the
  upstream project file list.

The membrane, keymap and `i2s_master` files belong to MiSTer's top level, not
the core, and stay candidates. Every imported file matched its audited blob.

One line of `rtl/serial/fifop.vhd` is modified. Upstream computes the
"almost full" flag by comparing `stored(DEPTH_BITS-1 downto 1)` with
`std_logic_vector(to_unsigned(-1, stored'length-1))`. Gowin rejects the
negative argument to `to_unsigned`. The two operands also differ in width, so
the comparison could never match on any toolchain. It now compares the slice
with an all-ones aggregate, which is what the "full - 2 bytes" comment
describes. The flag drives the UART receivers' RTR line when hardware flow
control is enabled. NextNano carries the same replacement in its Gowin build.

On 2026-10-27 nine files gain clock enables for the CPU's own clock, so the
Console 138K can run the CPU on `i_CLK_28` instead of a separate CPU clock:
`rtl/zxnext.vhd`, `rtl/cpu/t80na.vhd`, `rtl/device/dma.vhd`,
`rtl/device/im2_control.vhd`, `rtl/device/im2_device.vhd`,
`rtl/device/im2_peripheral.vhd`, `rtl/device/peripherals.vhd`,
`rtl/serial/spi_master.vhd` and `rtl/video/zxula.vhd`. Each process clocked
on an edge of the CPU clock gains a condition on a new enable input,
`rising_edge(i_CLK_CPU) and i_CPU_CEN_R = '1'` or the falling-edge equivalent
with `i_CPU_CEN_F`, and the inputs are passed down to the submodules that hold
such processes. In `t80na.vhd` the wrapper's own processes are gated the same
way and the inner T80N's existing `CEN` becomes `Spec256_cen and CEN_R`. Every
new input defaults to `'1'`, so a board that supplies a real CPU clock and
leaves them unconnected gets the upstream core unchanged; a simulation of the
whole core shows identical outputs on every 28 MHz edge for 4.5 million cycles
in that configuration. The reason, the enable generator and the equivalence
evidence are in the project wiki under
`raw/zxnext-single-clock-cpu-2026-10-27.md`.

Later the same day `rtl/zxnext.vhd` gains two more changes:

- **Interrupt pulse.** The pulsed interrupt counts its 32 (or 36) CPU cycles
  only while `i_CPU_WAIT` is low. The Z80 samples INT at the end of an
  instruction, and the Console's DDR3 can hold the CPU for longer than the
  whole pulse, which hid frame interrupts from a halted CPU in simulation. On
  a board where nothing drives `i_CPU_WAIT` the pulse is unchanged.
- **Debug outputs.** Four outputs give a debug view: `o_DEBUG_NR_WE`,
  `o_DEBUG_NR_REG` and `o_DEBUG_NR_DAT` show every NextREG write from the CPU
  or the copper, and `o_DEBUG_IORQ_n` is the CPU's IORQ, which `o_BUS_IORQ_n`
  hides for internal ports. Nothing inside the core reads them.
- **Reset type after a hard reset.** NextREG 0x02's reset type returns to its
  power-on value while `i_RESET` and `i_BOOT` are both high. A real Next
  reconfigures the FPGA on a hard reset, which does the same; without it a
  hard reset after a soft one was reported to software as a soft reset.
- **Layer 2 window.** A generic, `g_layer2_units`, passes to a new generic
  of the same purpose in `rtl/video/layer2.vhd`: one bit for each 16K unit
  of the 2MB space. Layer 2 pixels in a unit whose bit is clear are treated
  as transparent, as upstream already treats addresses past the end of
  memory. The Console 138K serves Layer 2 from a block RAM copy of part of
  memory and clears the bits for the rest. The default sets every bit, which
  is the upstream behaviour.

## Reference projects

These are read for their answers to device-specific questions. Nothing is
imported from them without going through the same audit as any other upstream.

[NextNano](https://github.com/RetroSilicon/NextNano) (GPL-3.0) is a ZX Spectrum
Next for the Tang Nano 20K. Different device to ours, a GW2AR-18 rather than a
GW5AST-138, and a different memory and video architecture, but the same vendor
toolchain and the same core lineage, so its answers to Gowin questions carry.
Consulted from 2026-08-18 at commit `ba1d834fb672c75a9482233557ae776602b1b243`.

Two of its findings confirm conclusions this project had already reached
independently: that Gowin's SDC parser requires every command on one physical
line, and that the `ioq` line above has to be rewritten to synthesize. Its
`t80n.vhd` carries the same replacement text.

No NextNano code is in this repository.

## The Next boot loader, built outside the repository

`rtl/rom/bootrom.vhd` stays excluded, but the program it holds has published
source. The official System/Next distribution carries the boot loader (the
IPL) in `src/firmware/loader`, with "Copyright 2020 Garry Lancaster, Fabio
Belavenuto & Victor Trucco" and GPL-3.0-or-later notices, and a GPL v3
`LICENSE` beside it. `scripts/build_next_ipl.sh` fetches that directory from
`https://gitlab.com/thesmog358/tbblue.git` at commit
`f287c48bf6af3528e32977b913bac2c589d9f973` and compiles it with SDCC 4.0.0 in
a Debian bullseye container pinned by digest. The published source lags the
binaries: `main.c` uses `RESET_POWERON`, which `hardware.h` no longer defines,
so the script defines it as `0x04` on the command line and leaves the source
untouched. The result is not byte-identical to MiSTer's `bootrom.vhd`, and
no SDCC version tried (3.8, 4.0, 4.2) reproduces it.

The image and the VHDL `build_zxnext.sh --boot-image` renders from it stay in
the build directory. Neither is committed, and nothing here distributes them;
the generated VHDL carries the loader's notice, not this project's. Whether a
released NextTang image may carry the loader is the open release question in
the project wiki, not something this build decides.

## Audit result

The audit covers all 145 paths tracked by the selected tree. The machine-readable
[per-file audit](upstream-files.tsv) records each path, Git blob, observed notice,
and planned disposition.

| Disposition | Files | Decision |
| --- | ---: | --- |
| GPL-3.0-or-later core candidate | 45 | May be imported with its existing notice and source history intact |
| BSD-style core candidate | 7 | May be imported with its existing notice intact and the synthesized-form notices shipped with bitstreams |
| MiSTer platform and framework | 66 | Reference only; replace with Tang platform code |
| Intel/Altera PLL files | 4 | Do not import; replace with Gowin clock generation |
| Upstream project files | 10 | Reference only; not part of the portable core import |
| Prebuilt releases | 11 | Do not import or redistribute |
| `rtl/audio/dac.vhd` | 1 | Do not import unless its licence provenance is established; otherwise reimplement |
| `rtl/rom/bootrom.vhd` | 1 | Do not import or redistribute; replace it with project-owned or independently licensed boot firmware |

The 52 candidate files are the portable ZXNext logic identified by this audit.
Their inclusion remains subject to review at the actual import commit.

## Licence conclusions

The 45 core files carry GPL-3.0-or-later notices. The seven BSD-style files are
the T80 CPU family, YM2149, and SPI master. Their terms permit redistribution in
source and synthesized forms, but require the copyright notices, conditions,
and disclaimer to accompany synthesized distributions. NextTang therefore
keeps [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) as release
documentation and must distribute it with every bitstream containing those
files.

The MiSTer wrapper contains a mixture of GPL-2.0-or-later,
GPL-3.0-or-later, vendor-generated, and files without an explicit per-file
licence notice. It is excluded from the portable import. Where GPL-2.0-or-later
wrapper code is studied or later adapted, its "or later" option is compatible
with NextTang's GPLv3 distribution, but its notice and provenance must still be
preserved.

Intel/Altera generated PLL sources include device-restricted terms and are not
portable to Gowin silicon. They and the entire `sys/` framework are excluded,
as are the opaque files under `releases/`.

## ROM and unresolved-source policy

`rtl/rom/bootrom.vhd` contains 8 KiB of machine-generated ROM data but no
copyright or licence notice establishing permission to redistribute it.
NextTang will neither import the data nor emit it into repository or release
artifacts. A build that needs it must accept a legally obtained, user-supplied
ROM outside Git and record only a non-reversible content hash in evidence.

`rtl/audio/dac.vhd` names Xilinx application note XAPP154 but carries no
copyright or licence notice. It is excluded until provenance is established;
the expected alternative is a clean, original implementation behind the audio
platform interface.

## File classification

Future source additions must be classified in their importing commit:

- **upstream** means an unmodified file copied from the pinned Git blob;
- **modified upstream** preserves the original notices and records the
  NextTang change and source blob;
- **generated** records the generator, exact version, inputs, command, and
  applicable vendor terms, without committing proprietary payloads; and
- **original** means authored for NextTang and distributed under GPLv3.

An upstream update requires a new pinned commit and tree, a regenerated
per-file audit, review of every changed notice or disposition, and a roadmap or
issue record. Blob IDs make renames and content changes independently
checkable.
