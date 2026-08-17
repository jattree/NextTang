# Toolchain setup

The repository has stable front-door commands, a Console 138K smoke-image
driver and a separate destructive DDR3 diagnostic driver. The smoke image and
DDR3 diagnostic are hardware-verified for the exact C device; this does not
verify the planned machine core or every advertised toolchain combination.

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

The release command builds the hardware-verified Console 138K smoke image. It
does not include the planned machine core or DDR3 controller.

### Local smoke-build evidence

On 2026-08-05, installed GOWIN EDA Standard `V1.9.12.03` synthesized, placed,
routed, timing-checked and packed a small resettable counter for candidate part
`GW5AST-LV138PG484AC1/I0`. The 10 MHz smoke constraint passed with zero setup or
hold violations and a fresh `.fs` file was generated.

The test used arbitrary package pins selected for toolchain validation. The
bitstream is not safe to program, does not use Console constraints, and does not
exercise NextTang sources, mixed-language synthesis, DDR3 or hardware.

Primary reference: [Sipeed Tang Mega 138K examples](https://github.com/sipeed/TangMega-138K-example),
including its [DDR memory notes](https://github.com/sipeed/TangMega-138K-example/blob/main/ddr_memory/README.md).

### Console 138K DDR3 diagnostic

The destructive diagnostic uses the exact C device and the Console's 50 MHz
input. Its working clock path retains Sipeed's Gowin-generated `Gowin_PLL`
wrapper, `PLL_INIT` sequencer and DDR3 controller. Those generated files do not
carry a redistribution grant, so they remain outside this repository.

Provide a local directory with this shape:

```text
ddr3_memory_interface/ddr3_memory_interface.v
gowin_pll/gowin_pll.v
gowin_pll/gowin_pll_mod.v
pll_init.v
```

Then run:

```bash
mkdir -p /tmp/nexttang-ddr3-build
boards/console138k/build_ddr3.sh \
  --toolchain vendor \
  --profile diagnostic \
  --vendor-source /absolute/path/to/ddr_memory_test_uart/src \
  --output /tmp/nexttang-ddr3-build
```

The output directory must exist and be empty. The driver rejects tool error
records, requires fresh synthesis, placement, timing and bitstream artifacts,
requires zero setup and hold violations, and writes source hashes and a build
manifest. The generated bitstream is destructive to the tested addresses and
must not be committed.

Gowin EDA V1.9.12.03 produced the hardware-verified build. The current
diagnostic proves calibration and distinct retained transactions at every
usable 1 GiB address-line position and the final aligned beat. This rejects
aliasing among those probes, but is not an exhaustive every-cell or sustained
traffic test.

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

On 2026-08-05, OSS CAD Suite `2026-08-05`, Yosys `0.67+153`,
nextpnr `0.10-117-g8d8053e0` and `gowin_pack` processed the same counter for the
same candidate part through bitstream generation. The 10 MHz constraint passed.
This validates a small pure-Verilog tool path only; the same board, pin and
hardware limits as the vendor smoke build apply.

Primary references:

- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
- [Yosys releases](https://github.com/YosysHQ/yosys/releases)
- [nextpnr releases](https://github.com/YosysHQ/nextpnr/releases)
- [Project Apicula](https://github.com/YosysHQ/apicula)
- [openFPGALoader releases](https://github.com/trabucayre/openFPGALoader/releases)

## Required build acceptance checks

The adjacent-project review found that `gw_sh` can return zero after logging
missing-source errors, and that stale checked-in implementation output can hide
the absence of a fresh bitstream. A generated bitstream can also coexist with
setup or hold violations.

A NextTang board driver must therefore fail unless the current invocation:

1. starts with an empty, target-specific output directory;
2. completes without tool error records, regardless of process exit status;
3. creates fresh synthesis, placement, timing and utilisation reports;
4. creates the expected fresh bitstream;
5. records the exact device, tool version, target and profile; and
6. meets every timing constraint required by that profile.

Warnings remain reviewable evidence and must not be discarded. The driver should
classify known warnings explicitly rather than treating all warning text as either
success or failure. See the [adjacent-project review](adjacent-projects.md) for
the observations that established these requirements.

Related-project issue histories add one more requirement: pin the exact tool
patch release and complete source tree. NESTang and SNESTang report different
resource or display results across Gowin patch releases. TangCore has a reported
missing pinned submodule object, and its reviewed source tree does not reproduce
every Console image in its release. These are upstream reports, not NextTang
results, but they rule out treating a release label, a nearby tool version or a
binary archive as a reproducible build. Record root and submodule commits, the
exact tool build, the manifest and fresh output hashes for every promoted result.

## Promoting a toolchain version

Change `provisional-unvalidated` only after the exact tool build, source revision,
device/package, board revision, commands, output hashes, timing/utilization report,
and hardware observation are recorded in a linked GitHub issue or pull request and
the maintained project documentation. A version that works for one target or
silicon revision is not automatically validated for another.
