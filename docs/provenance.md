# Upstream provenance and import policy

NextTang has selected the MiSTer ZXNext repository at commit
[`1c7db8649193c109ea292d82d1f729d22eb1f5e7`](https://github.com/MiSTer-devel/ZXNext_MISTer/commit/1c7db8649193c109ea292d82d1f729d22eb1f5e7)
(`Release 20260603`) as the baseline for the first port. Its Git tree is
`e2febf8f495714629a279693ce2d9dd7d2d757ab`.

The first import from that repository landed on 2026-08-18: the five T80 CPU
family files under `rtl/cpu/`, taken byte-identical from the pinned commit and
verified against the Git blob hashes recorded in
[the per-file audit](upstream-files.tsv). Their notices are retained unmodified
in the sources, and `THIRD_PARTY_NOTICES.md` must accompany any synthesized
artifact built from them.

Nothing else has been imported. Selecting and auditing a baseline is not a
build, simulation, synthesis, or hardware result, and importing source is not a
claim that it works on this hardware: the T80 files have not yet been wired to
anything, simulated, or synthesized in this project.

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
