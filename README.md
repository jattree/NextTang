<p align="center">
  <img src="./assets/readme/hero.png" width="100%" alt="NextTang: ZX Spectrum Next on Sipeed Tang FPGA">
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: GPL v3" src="https://img.shields.io/github/license/jattree/NextTang?style=flat-square&amp;color=0ea5e9"></a>
  <a href="https://github.com/jattree/NextTang/actions/workflows/quality.yml"><img alt="Quality checks" src="https://img.shields.io/github/actions/workflow/status/jattree/NextTang/quality.yml?branch=main&amp;style=flat-square&amp;label=quality"></a>
  <a href="#current-status"><img alt="Status: first hardware image" src="https://img.shields.io/badge/status-first_hardware_image-f97316?style=flat-square"></a>
  <a href="#hardware-targets"><img alt="Targets: Tang Nano 20K, Console 60K, and Console 138K" src="https://img.shields.io/badge/targets-Nano_20K_%7C_Console_60K_%7C_138K-334155?style=flat-square"></a>
  <a href="https://t.me/NextTang"><img alt="Telegram: NextTang" src="https://img.shields.io/badge/Telegram-NextTang-26A5E4?style=flat-square&amp;logo=telegram&amp;logoColor=white"></a>
  <a href="https://www.youtube.com/@NextTangFPGA"><img alt="YouTube: NextTang" src="https://img.shields.io/badge/YouTube-NextTang-FF0000?style=flat-square&amp;logo=youtube&amp;logoColor=white"></a>
  <a href="https://github.com/jattree/NextTang/issues"><img alt="Open issues" src="https://img.shields.io/github/issues/jattree/NextTang?style=flat-square"></a>
</p>

<p align="center">
  <a href="ROADMAP.md">Roadmap</a> ·
  <a href="#hardware-targets">Hardware targets</a> ·
  <a href="docs/provenance.md">Provenance</a> ·
  <a href="docs/toolchain.md">Toolchain</a> ·
  <a href="https://t.me/NextTang">Telegram</a> ·
  <a href="https://www.youtube.com/@NextTangFPGA">YouTube</a> ·
  <a href="#contributing">Contributing</a> ·
  <a href="#references">References</a>
</p>

## Current status

> [!IMPORTANT]
> The first NextTang-owned Console 138K smoke image is hardware-verified. It is
> a board and video test, not the ZX Spectrum Next machine core, and establishes
> no software-compatibility claim.

The image loads into volatile FPGA SRAM through the onboard debugger and
generates DVI-compatible 1280 x 720/60 HDMI colour bars with a moving NextTang
logo. The exact C-device build reports zero setup and hold violations. Source,
constraints and behavioural tests are under [`boards/console138k/`](boards/console138k/),
[`rtl/smoke/`](rtl/smoke/) and
[`tests/test_console138k_smoke.py`](tests/test_console138k_smoke.py). Generated
bitstreams remain outside Git.

Bring-up status is deliberately split between NextTang-owned behaviour and the
factory TangCore baseline:

| Area | Current evidence |
| --- | --- |
| JTAG and programming | Hardware-verified 6 MHz scan and volatile SRAM loading; Gowin `GW5AST-138`, IDCODE `0x1081b` |
| Clocks | Video-clock path hardware-verified indirectly through stable 720p60 output; standalone 28, 14, 7 and 3.5 MHz machine-clock logic is simulation- and exact-device build-verified, but not connected to the core or hardware-verified |
| UART | Behaviourally tested and included in the smoke image, but the attempted hardware read did not decode correctly |
| HDMI | Hardware-verified for 720p60 video, colour, logo rendering and frame-driven motion; no HDMI audio |
| DDR3 | Hardware-verified on the 30354 1 GB Hynix SOM: calibration, paired writes, read-back, every usable address-line position, the 512 MB boundary and the final aligned 32-byte beat pass with distinct retained patterns. The Console input is 50 MHz and the working path retains Gowin's generated dynamic PLL and `PLL_INIT`. Exhaustive every-cell and sustained-load testing remain open ([resolved issue #5](https://github.com/jattree/NextTang/issues/5)) |
| SD | Factory TangCore reads the supplied card and loads packaged cores; no NextTang SD implementation |
| Audio | Not brought up |
| USB HID | The supplied controller navigates factory TangCore; no NextTang USB HID implementation |

The next engineering gates are connecting the machine clock and CPU memory
service to the working DDR3 controller, then open boot, storage, input and audio
before any ZX Spectrum Next compatibility claim. The
[starter roadmap](ROADMAP.md) defines the required evidence.

The one part of the project not waiting on that board is the
[host tooling track](ROADMAP.md#host-tooling-track), which builds the DZRP client and
command-subset conformance suite against existing remotes.

## What NextTang is

NextTang is an independent, community-developed port of the
[ZX Spectrum Next](https://www.specnext.com/) FPGA implementation to
[Sipeed Tang Console](https://wiki.sipeed.com/hardware/en/tang/tang-console/mega-console.html)
boards. The initial hardware target is the Tang Console 138K, with a shared
platform design intended to support the Tang Console 60K as well.

The project starts from the actively maintained
[MiSTer ZXNext core](https://github.com/MiSTer-devel/ZXNext_MISTer), which is a
port of the [official ZX Spectrum Next FPGA sources](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA).
It will replace the MiSTer-specific platform layer with a Gowin/Tang platform
shell rather than reimplementing the Next specification from scratch.

The project grew from the community discussion about the unavailable
[NextNano v0.1 corresponding source](https://github.com/RetroSilicon/NextNano/issues/1).
NextTang does not depend on that source becoming available, but future
cooperation or code sharing is welcome where technically and legally possible.

## Goals

- Boot and run ZX Spectrum Next software on supported Tang Console boards.
- Keep the ZXNext logic close to its upstream source and isolate board-specific
  clocks, memory, video, audio, storage, and input behind narrow interfaces.
- Support both 60K and 138K targets from one source tree rather than through
  divergent forks.
- Add developer-oriented hardware debugging: halt, step, registers, MMU state,
  page-aware breakpoints, watchpoints, and triggered instruction tracing.
- Publish source, build instructions, exact tool versions, test artifacts, and
  known compatibility limits.

## Non-goals

- Claiming endorsement by or equivalence to official ZX Spectrum Next hardware.
- Treating emulator or alternate-FPGA results as official-hardware proof.
- Redistributing NextZXOS, ROMs, games, or other third-party copyrighted files.
- Making the first bitstream wait for the complete debugger.

## Hardware targets

| Target | Intended role | Status |
| --- | --- | --- |
| Tang Console 138K | Initial port, full development instrumentation, deep trace | Hardware received; `GW5AST-LV138PG484AC1/I0` visually identified, `GW5AST-138` JTAG identity verified, and first owned 720p60 smoke image hardware-verified |
| Tang Console 60K | Portable release core and lighter debugging | Planned; contributor wanted |
| Tang Nano 20K | Later compact release target; not a development platform | In scope; not currently scheduled |

Both Console targets will use the same core and debugger protocol. Features
that depend on available FPGA resources will be discovered at runtime through a
capability bitmap instead of creating incompatible tools.

## Planned build profiles

| Profile | Purpose | Expected targets |
| --- | --- | --- |
| `release` | Smallest compatible core without development instrumentation | 60K and 138K |
| `debug-lite` | Halt, step, state inspection, and a small breakpoint set | 60K and 138K if synthesis permits |
| `debug-full` | Extended watchpoints and deep triggered trace | 138K initially |

Resource availability is not assumed. Each profile must pass synthesis and
timing analysis on its exact FPGA device and board revision.

## Planned architecture

```text
rtl/                 Shared ZXNext RTL
platform/common/     Shared platform and capability interfaces
boards/nano20k/      20K compact release top level and constraints
boards/console60k/   60K top level, constraints, PLL, and memory IP
boards/console138k/  138K top level, constraints, PLL, and memory IP
debug/               Debug control, breakpoints, watchpoints, and trace
host/                Host-side protocol tools and debugger integration
sim/                 Portable simulations and fixtures
tests/               Build, compatibility, and hardware smoke tests
docs/                Architecture, provenance, and verification records
```

The [starter roadmap](ROADMAP.md) turns this structure into milestones with
explicit completion evidence.

## Developer setup

The repository has deterministic quality checks and fail-closed synthesis entry
points. The Console 138K has a vendor `release` driver for the verified smoke
image. This driver does not build the planned machine core.

```bash
cp .env.example .env.local
make doctor
make check
make show-config
make TOOLCHAIN=vendor TARGET=console138k PROFILE=release synth
```

The hardware-verified destructive DDR3 diagnostic has a separate build entry
because its generated Gowin controller and PLL sources cannot be redistributed
by this repository. Generate or obtain the matching files locally, keep them
outside Git, then provide their containing directory explicitly:

```bash
mkdir -p /tmp/nexttang-ddr3-build
boards/console138k/build_ddr3.sh \
  --toolchain vendor \
  --profile diagnostic \
  --vendor-source /absolute/path/to/ddr_memory_test_uart/src \
  --output /tmp/nexttang-ddr3-build
```

The driver requires an empty output directory, checks fresh reports and timing,
and records repository and vendor-source hashes beside the generated bitstream.

See the [toolchain guide](docs/toolchain.md) for the provisional Gowin and
open-source tool versions and supported target/profile combinations. Other
target, profile and toolchain combinations remain unimplemented and fail closed.
Board integrations must implement the documented
[build-driver contract](boards/README.md).

Public technical decisions and verification evidence belong in the relevant
documentation, GitHub issue, or pull request so contributors can inspect and
reproduce them.

## Contributing

The project is at the stage where early hardware and toolchain experience has
high leverage. Useful contribution areas include:

- Tang Console 60K or 138K board ownership and repeatable hardware testing;
- Gowin EDA, [Yosys](https://github.com/YosysHQ/yosys),
  [nextpnr](https://github.com/YosysHQ/nextpnr), or
  [Project Apicula](https://github.com/YosysHQ/apicula) experience;
- mixed VHDL/SystemVerilog integration;
- DDR3, HDMI, SD, USB HID, and onboard USB controller firmware;
- Z80N/Next compatibility testing; and
- FPGA trace and source-debugger design.

Read [CONTRIBUTING.md](CONTRIBUTING.md), then start with a
[GitHub issue](https://github.com/jattree/NextTang/issues) stating
which board and exact silicon revision you have, which operating system and
toolchain you can use, and the area you would like to work on. Small,
independently verifiable contributions are preferred.

Project discussion, coordination, announcements, and roadmap updates are hosted
in the [NextTang Telegram group](https://t.me/NextTang). Less technical project
updates and build videos are on the [NextTang YouTube channel](https://www.youtube.com/@NextTangFPGA).

## References

- [Official ZX Spectrum Next FPGA repository](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA)
- [MiSTer ZXNext core](https://github.com/MiSTer-devel/ZXNext_MISTer)
- [Pinned upstream and per-file provenance audit](docs/provenance.md)
- [Adjacent Tang project evidence and reuse boundaries](docs/adjacent-projects.md)
- [YouTube channel CLI for project host tooling](docs/youtube-cli.md)
- [Sipeed Tang Console documentation](https://wiki.sipeed.com/hardware/en/tang/tang-console/mega-console.html)
- [Sipeed Tang Mega 138K examples](https://github.com/sipeed/TangMega-138K-example)
- [ZXSpectrumNextTests](https://github.com/MrKWatkins/ZXSpectrumNextTests)
- [DeZog Remote Protocol](https://github.com/maziac/DeZog/blob/main/design/DeZogProtocol.md)
- [JNext emulator and debugger](https://github.com/jorgegv/jnext)
- [dezogif](https://github.com/maziac/dezogif) and
  [dezogif_ng](https://github.com/jorgegv/dezogif_ng), DZRP debug stubs for real Next hardware
- [NextNano source discussion](https://github.com/RetroSilicon/NextNano/issues/1)

## Independence and license

NextTang is not affiliated with or endorsed by SpecNext Ltd, Sipeed, MiSTer,
or RetroSilicon. Product and project names belong to their respective owners.

Original work in this repository is released under the
[GNU General Public License v3.0](LICENSE). Imported source will retain its
copyright, attribution, modification notices, and license terms. The
[upstream audit and import policy](docs/provenance.md) records the selected
baseline before any upstream HDL is committed. Synthesized releases containing
the audited BSD-style components must include
[the third-party notices](THIRD_PARTY_NOTICES.md).
