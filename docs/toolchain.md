# Toolchain setup

The repository now has stable front-door commands and version references, but it
does not yet contain synthesis drivers or a working NextTang bitstream. Tool
versions in [`toolchain/versions.env`](../toolchain/versions.env) remain
`provisional-unvalidated` until an exact build and hardware result are logged.

## Common setup

Copy `.env.example` to `.env.local`, select a target, and point it at your local
installation. `.env.local` is ignored and must not contain a vendor license or
credentials.

```bash
cp .env.example .env.local
make show-config
make doctor
make check
```

The stable commands are:

| Command | Purpose |
| --- | --- |
| `make help` | List supported entry points |
| `make show-config` | Show toolchain, target, profile, and output directory |
| `make doctor` | Report both toolchains without failing for missing FPGA tools |
| `make doctor-strict TOOLCHAIN=vendor` | Require one selected toolchain |
| `make check` | Run deterministic repository, shell, wiki, and unit checks |
| `make synth TOOLCHAIN=... TARGET=... PROFILE=...` | Run a real board driver, once implemented |
| `make clean` | Remove only this repository's `build/` directory |

Builds are isolated under `build/<toolchain>/<target>/<profile>/`. The directory
is ignored by Git.

## Gowin vendor flow

The first 138K bring-up should use the vendor flow because Sipeed's DDR3 example
records **Gowin EDA V1.9.12.02_SP1, build 84852**. Its project selects
`GW5AST-138C` with part `GW5AST-LV138PG484AC1/I0`. Other Sipeed examples select B
silicon and different part variants, so the board's marking must be checked rather
than inferred. Regenerate Gowin-specific PLL, DDR, and other IP for the exact B/C
device and selected EDA release.

Install Gowin EDA according to its license, source the environment that provides
`gw_sh`, then run:

```bash
make doctor-strict TOOLCHAIN=vendor
make synth TOOLCHAIN=vendor TARGET=console138k PROFILE=release
```

The synthesis command currently stops before invoking Gowin because the 138K board
driver has not been implemented. That failure is intentional.

Primary reference: [Sipeed Tang Mega 138K examples](https://github.com/sipeed/TangMega-138K-example),
including its [DDR memory notes](https://github.com/sipeed/TangMega-138K-example/blob/main/ddr_memory/README.md).

## Experimental open-source flow

The provisional reference is OSS CAD Suite `2026-08-02`, containing the project's
required tools. Standalone reference versions are Yosys `0.67`, nextpnr `0.10` or
newer, and openFPGALoader `1.1.1`. nextpnr 0.10 describes GW5AST-138C support as
initial support; that is a starting point, not proof that the complete Next core,
mixed VHDL/SystemVerilog input, DDR3 IP, or timing closure works.

Source the OSS CAD Suite environment, then run:

```bash
make doctor-strict TOOLCHAIN=oss
make synth TOOLCHAIN=oss TARGET=console138k PROFILE=release
```

The doctor requires `yosys`, `nextpnr-himbaechel`, `gowin_pack`, `ghdl`, and
`openFPGALoader`. GHDL is included because the planned upstream core is VHDL-heavy,
but the exact mixed-language synthesis boundary remains to be proven. Do not use
the open flow for a release claim until synthesis, timing, programming, and hardware
tests have all been reproduced.

Primary references:

- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
- [Yosys releases](https://github.com/YosysHQ/yosys/releases)
- [nextpnr releases](https://github.com/YosysHQ/nextpnr/releases)
- [Project Apicula](https://github.com/YosysHQ/apicula)
- [openFPGALoader releases](https://github.com/trabucayre/openFPGALoader/releases)

## Promoting a toolchain version

Change `provisional-unvalidated` only after the exact tool build, source revision,
device/package, board revision, commands, output hashes, timing/utilization report,
and hardware observation are recorded in a linked GitHub issue or pull request and
the maintained project documentation. A version that works for one target or
silicon revision is not automatically validated for another.
