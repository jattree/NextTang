# Contributing to NextTang

NextTang is early enough that repeatable evidence matters more than large changes.
Please open an issue before substantial work so contributors with different boards
and toolchains can coordinate.

## Set up the repository

1. Install Git, GNU Make, Bash, and Python 3.12.
2. Copy `.env.example` to `.env.local` and adjust paths for your machine.
3. Follow [the toolchain guide](docs/toolchain.md) for Gowin EDA or the experimental
   open-source flow.
4. Run `make doctor`, then `make check`.

The deterministic checks do not need an FPGA toolchain. A real synthesis command
does: `make synth TOOLCHAIN=vendor TARGET=console138k PROFILE=release`.

## Change workflow

- Keep changes small enough to review and reproduce independently.
- Add or update tests when behavior changes.
- Do not commit generated bitstreams, implementation directories, timing reports,
  waveforms, local captures, vendor binaries, credentials, or license files.
- Keep locally owned ROMs, games, SD-card trees, vendor payloads, and downloaded
  test media under `local/`; the directory and common Spectrum media formats are
  ignored and rejected by the repository check if force-added.
- Preserve copyright, license, and modification notices on imported files.
- Record the source revision and provenance before importing upstream HDL.
- Run `make check` before pushing.

Build drivers must follow the contract in [boards/README.md](boards/README.md).
Durable public decisions and verification results belong in the relevant project
documentation, GitHub issue, or pull request.

## Hardware evidence

A hardware result should state all of the following:

- board name, PCB revision, FPGA device/package, and B/C silicon revision;
- Git commit and whether the worktree was clean;
- tool name, exact version/build, and selected target/profile;
- commands used and hashes of test inputs or generated artifacts;
- observed output, expected output, duration or repetition count, and failures;
- relevant utilization, timing slack, clocks, and programmer settings.

Label simulation, Tang Nano 20K, Tang Console 60K, Tang Console 138K, and official
ZX Spectrum Next evidence separately. One does not prove another.

## Pull requests

Describe the problem, the narrow change, and how another contributor can verify it.
For a hardware-dependent change, attach or link the evidence above and name a safe
rollback point or known-good bitstream when one exists.
