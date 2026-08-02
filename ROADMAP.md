# NextTang Starter Roadmap

This roadmap orders the work by risk and evidence. It deliberately has no
delivery dates yet. A milestone is complete only when its source, repeatable
commands, exact tool and hardware versions, results, and known limitations are
committed to the repository.

The [MiSTer ZXNext core](https://github.com/MiSTer-devel/ZXNext_MISTer) is the
planned implementation baseline. The
[official ZX Spectrum Next FPGA repository](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA)
and [ZXSpectrumNextTests](https://github.com/MrKWatkins/ZXSpectrumNextTests)
provide specification and compatibility references.

## Milestone 0: Project baseline

- [x] Create the public repository and choose the GPLv3 license foundation.
- [x] Define Tang Console 138K as the initial target and Tang Console 60K as a
  shared-source target.
- [ ] Record the exact MiSTer upstream commit selected for the first port.
- [ ] Audit licenses and per-file notices before importing upstream source.
- [ ] Add a provenance document distinguishing upstream, modified, generated,
  and original files.
- [ ] Record supported board, package, and B/C silicon revisions.
- [x] Document contributor workflow, formatting, review, and evidence rules.

**Exit evidence:** pinned upstream revisions, a completed license/provenance
review, and an agreed target matrix.

## Milestone 1: Toolchain and board bring-up

Use the
[Sipeed Tang Mega 138K examples](https://github.com/sipeed/TangMega-138K-example)
and [Tang Console documentation](https://wiki.sipeed.com/hardware/en/tang/tang-console/mega-console.html)
as board references.

- [ ] Pin a known-working Gowin EDA version and archive its synthesis/timing
  reports without committing proprietary vendor payloads.
- [ ] Evaluate the open flow using
  [Yosys](https://github.com/YosysHQ/yosys),
  [nextpnr-himbaechel](https://github.com/YosysHQ/nextpnr), and
  [Project Apicula](https://github.com/YosysHQ/apicula); document unsupported
  IP or mixed-language boundaries honestly.
- [x] Add fail-closed build entry points, environment diagnostics, repository
  checks, and provisional version references without claiming synthesis support.
- [ ] Reproduce LED/reset and UART operation on the exact 138K board revision.
- [ ] Reproduce HDMI color bars and stable video clocks.
- [ ] Reproduce DDR3 initialization, bounded memory testing, and UART results.
- [ ] Reproduce SD access, I2S audio, and USB HID independently.
- [ ] Capture utilization, timing slack, clock definitions, and all generated-IP
  provenance.

**Exit evidence:** clean builds and hardware logs for each isolated peripheral,
plus a toolchain decision for the first integrated build.

## Milestone 2: Portable platform shell

- [ ] Define stable interfaces for clocks/reset, main RAM, boot storage, video,
  audio, keyboard/mouse/gamepad, UART, and debug control.
- [ ] Create `boards/console138k` without leaking device primitives into shared
  RTL.
- [ ] Add asynchronous-boundary handling and assertions where clocks differ.
- [ ] Define bounded memory requests and explicit wait-state behavior.
- [ ] Add simulation fixtures for reset, memory arbitration, and peripheral
  handshakes.
- [ ] Produce a shell bitstream that exercises all interfaces without the
  ZXNext core.

**Exit evidence:** the platform-shell simulation passes and one 138K bitstream
demonstrates every required physical interface independently.

## Milestone 3: First ZXNext boot on 138K

- [ ] Import the pinned MiSTer ZXNext source with complete notices and a minimal
  patch series.
- [ ] Replace MiSTer HPS, Intel PLL, and memory wrappers with the NextTang
  platform interfaces.
- [ ] Synthesize early and record resource use before optimizing anything.
- [ ] Reach a deterministic configuration or boot screen at 3.5 MHz and 50 Hz.
- [ ] Load user-supplied ROM/NextZXOS content without redistributing it.
- [ ] Bring up keyboard, SD loading, HDMI audio/video, and UART diagnostics.
- [ ] Preserve a first-boot test artifact and exact reproduction instructions.

**Exit evidence:** a fresh checkout builds a bitstream that boots repeatedly on
the recorded 138K setup, with failures visible over UART.

## Milestone 4: Baseline compatibility and 60K target

- [ ] Add and verify 7, 14, and 28 MHz modes with measured wait-state behavior.
- [ ] Add 50/60 Hz switching, audio sources, mouse, and gamepad support.
- [ ] Implement `boards/console60k` behind the same platform interfaces.
- [ ] Synthesize `release` for both targets on every core change.
- [ ] Add a shared hardware smoke suite for CPU, NextREGs, MMU paging, video
  layers, sprites, tilemap, DMA, interrupts, SD, input, and audio.
- [ ] Record differences between 60K and 138K rather than hiding them with
  board-specific core forks.

**Exit evidence:** the same smoke artifacts pass on both boards, or each known
difference has a minimal reproduction and an open issue.

## Milestone 5: Verification ladder

- [x] Add deterministic repository, shell, LLM-wiki, and command-dispatch checks
  that do not require FPGA tools.
- [ ] Add linting, mixed-language compilation, simulation, and synthesis CI.
- [ ] Pin test artifacts by hash and generate machine-readable evidence reports.
- [ ] Compare failing behavior with the
  [official FPGA sources](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA),
  [MiSTer ZXNext](https://github.com/MiSTer-devel/ZXNext_MISTer),
  [ZXSpectrumNextTests](https://github.com/MrKWatkins/ZXSpectrumNextTests), and
  appropriate emulators.
- [ ] Maintain distinct evidence labels for simulation, Tang 60K hardware, Tang
  138K hardware, and official Next hardware.
- [ ] Define regression and rollback criteria before replacing a known-good
  bitstream.

**Exit evidence:** compatibility claims point to reproducible test results and
never imply that alternate FPGA evidence proves official-hardware parity.

## Milestone 6: Debug-lite

- [ ] Specify a versioned transport protocol with capability discovery.
- [ ] Keep the debug transport alive in a clock domain independent of the
  machine being inspected.
- [ ] Implement distinct CPU-halt and whole-machine-freeze semantics.
- [ ] Expose an explicit instruction-retirement event for reliable single-step.
- [ ] Read registers, NextREGs, MMU mappings, and physical memory safely.
- [ ] Add page-aware execution breakpoints and a bounded breakpoint count.
- [ ] Implement UART transport and a small host command-line client.
- [ ] Attempt `debug-lite` synthesis and timing closure on both 60K and 138K.

**Exit evidence:** scripted halt, inspect, step, continue, and breakpoint tests
pass without changing the program result when debugging is disabled.

## Milestone 7: Debug-full and source integration

- [ ] Add read/write watchpoints with explicit CPU/DMA ownership semantics.
- [ ] Add a triggered circular trace containing instruction, physical page,
  memory-write, interrupt, and timing information.
- [ ] Bound trace storage and define deterministic overflow behavior.
- [ ] Evaluate higher-bandwidth USB transport through the Tang Console BL616.
- [ ] Add SLD/source-map loading and page-aware symbol resolution.
- [ ] Investigate a hardware backend for the
  [JNext debugger](https://github.com/jorgegv/jnext) rather than duplicating its
  source display and stepping user interface.
- [ ] Measure debug logic resource use and timing impact for every build profile.

**Exit evidence:** a source-level test can stop at a page-qualified breakpoint,
inspect state, step forward, and resume with documented timing effects. Reverse
execution, if later implemented, requires separately proven state
capture/restore and is not implied by instruction tracing alone.

## Milestone 8: Release candidate

- [ ] Publish reproducible release and debug builds with source revision,
  toolchain, board revision, utilization, timing, and test evidence.
- [ ] Publish installation, recovery, and known-limitations documentation.
- [ ] Run long-duration NextZXOS, SD, input, HDMI, and audio tests on both boards.
- [ ] Complete official-hardware comparisons for claims that require them.
- [ ] Establish maintainers and an upstream-update procedure.

**Exit evidence:** a new contributor can build, program, test, recover, and
diagnose both supported targets using only the published instructions and
legally obtained external software.

## Parallel contribution lanes

| Lane | Early work that can proceed independently |
| --- | --- |
| 138K hardware | Reproduce examples, pin constraints/IP, capture reports |
| 60K hardware | Inventory revisions, reproduce equivalent peripherals, prepare constraints |
| Core integration | Pin upstream, audit provenance, isolate platform dependencies |
| Simulation | Reset, memory, clock-domain, and bus-handshake fixtures |
| Verification | Select small cross-platform Next tests and evidence formats |
| Debugger | Protocol, capability model, halt semantics, and host CLI design |
| BL616 | Document existing firmware path and prototype a bounded debug transport |

Coordination happens through the
[NextTang issue tracker](https://github.com/jattree/NextTang/issues). Each task
should name an owner, the hardware/toolchain it needs, and an observable
completion condition.
