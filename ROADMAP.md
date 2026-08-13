# NextTang Starter Roadmap

This roadmap orders the work by risk and evidence. It deliberately has no
delivery dates yet. A milestone is complete only when its source, repeatable
commands, exact tool and hardware versions, results, and known limitations are
committed to the repository.

The [MiSTer ZXNext core](https://github.com/MiSTer-devel/ZXNext_MISTer) is the
planned implementation baseline. The
[official ZX Spectrum Next FPGA repository](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA)
and [ZXSpectrumNextTests](https://github.com/MrKWatkins/ZXSpectrumNextTests)
provide specification and compatibility references. The debugger targets the
[DeZog Remote Protocol](https://github.com/maziac/DeZog/blob/main/design/DeZogProtocol.md)
so that existing Z80 tooling works against NextTang hardware.

RetroSilicon's
[NextNano v0.2 work-in-progress source](https://github.com/RetroSilicon/NextNano/tree/ba1d834fb672c75a9482233557ae776602b1b243)
is a secondary design reference, not a replacement baseline. Its Gowin clock-enable,
memory CDC, diagnostics, and timing-constraint patterns will be evaluated individually.
Its Nano 20K SDR SDRAM controller, platform-specific core changes, and file-level licence
boundaries do not transfer automatically to the Console 138K DDR3 target.

The numbered milestones are gated on Tang Console hardware. The
[host tooling track](#host-tooling-track) and
[source-assimilation track](#source-assimilation-track) are not, and can proceed now.
Core bring-up does not depend on the optional PCIe experiment.

## Host tooling track

This track runs alongside the milestone sequence rather than inside it, because its gate is
different. Milestone 1 onward waits on a Tang Console board. The host side of the debugger
waits on a DZRP remote to talk to, which can be real ZX Next hardware running
[dezogif](https://github.com/maziac/dezogif), or
[JNext](https://github.com/jorgegv/jnext) once it implements DZRP. Neither needs a Tang
board, and neither is in hand yet, so this track is gated on a remote rather than on
hardware NextTang controls.

- [ ] Build a DZRP host client that treats the remote as interchangeable, so one client
  drives dezogif on real Next hardware, JNext, and later NextTang.
- [ ] Build a command-subset conformance suite keyed by remote **and mode**, recording
  which DZRP commands are implemented and what each returns when asked for one it is
  not. One machine can expose two remotes: an out-of-band one, meaning the fabric debug
  unit on NextTang or the emulator itself in JNext, and an in-band one, meaning a
  guest-side stub such as `dezogif_ng` running as ordinary Next software. Their subsets
  differ, because in-band mode is limited by what a Z80 stub can do to its own machine
  rather than by the target's capability. A table keyed by remote alone will need
  reworking.
- [ ] Run the suite against at least two remotes NextTang did not write, before NextTang
  implements any of the protocol itself.
- [ ] Keep the client and suite useful to other DZRP remotes rather than specialising them
  to NextTang.

**Exit evidence:** the conformance suite produces a recorded per-command result table for a
remote this project did not write, which gives Milestone 6 an acceptance test before it has
an implementation.

## Source-assimilation track

This track converts public-source findings into bounded inputs for the numbered milestones.
It can proceed before the Tang Console arrives, but it cannot produce build or hardware
support claims.

- [x] Pin and source-review NextNano's first public source snapshot at commit
  `ba1d834fb672c75a9482233557ae776602b1b243` against the selected MiSTer baseline.
- [ ] Maintain a disposition ledger for each NextNano pattern or proposed import, recording
  provenance, licence, behavioral effect, target dependence, and whether NextTang will
  study, reimplement, port, or reject it.
- [ ] Complete the [DDR3 adapter simulation contract](https://github.com/jattree/NextTang/issues/4):
  model bounded CPU waits and an unstalled video port, keep accepted request metadata stable
  through acknowledgement, handle a second request explicitly, inject DDR3 refresh stalls,
  and expose underflow or stale-pixel failures.
- [ ] Prototype the buffered Layer 2 service in simulation, including the 256x192 row-major
  layout and the 320x256/640x256 column-major layouts, before fixing final hardware sizes.
- [ ] Turn compatibility-affecting differences observed in NextNano, including clock enables,
  software CPU-speed writes, UART, and expansion-bus behaviour, into tests or explicit exclusions
  before considering a corresponding core patch.
- [ ] Keep platform logic outside the shared core wherever the selected MiSTer interface
  permits it; every necessary core change gets a minimal patch and regression test.

**Exit evidence:** a provenance/disposition ledger exists and a named simulation satisfies
issue 4's acceptance criteria across every Layer 2 layout under declared refresh and latency
injection. This evidence remains simulated, not synthesized or hardware-verified.

## Milestone 0: Project baseline

- [x] Create the public repository and choose the GPLv3 license foundation.
- [x] Define Tang Console 138K as the initial target and Tang Console 60K as a
  shared-source target.
- [x] Record the exact MiSTer upstream commit selected for the first port.
- [x] Audit licenses and per-file notices before importing upstream source.
- [x] Add a provenance document distinguishing upstream, modified, generated,
  and original files.
- [ ] Record supported board, package, and B/C silicon revisions after the
  purchased 138K hardware arrives and can be inspected.
- [x] Document contributor workflow, formatting, review, and evidence rules.

The [provenance audit](docs/provenance.md) pins the selected upstream tree and
records every upstream file. Milestone 0 remains open only for exact hardware
identity; purchasing a board is not hardware verification.

**Exit evidence:** pinned upstream revisions, a completed license/provenance
review, and an agreed target matrix with the physical board identity recorded.

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
- [ ] Record how an official-hardware result was obtained. A guest-side DZRP stub such as
  [dezogif](https://github.com/maziac/dezogif) runs on the machine's own Z80 and takes
  over through NMI, so it observes architectural state well and timing poorly. Contention,
  wait states, and cycle counts measured that way are not equivalent to an instrumented or
  fabric-side measurement, and the label must say which produced the number.
- [ ] Quantify that distortion rather than only warning about it. JNext plans both an
  out-of-band DZRP implementation and an in-band one that loads a guest stub into the
  emulated machine, so running one program under both modes isolates the stub's own
  observational cost against a reference that perturbs nothing. Real hardware offers no
  uninstrumented reference to diff against, so this number is only obtainable in an
  emulator, and it bounds the error on every in-band hardware result.
- [ ] Define regression and rollback criteria before replacing a known-good
  bitstream.

**Exit evidence:** compatibility claims point to reproducible test results and
never imply that alternate FPGA evidence proves official-hardware parity.

## Milestone 6: Debug-lite

- [ ] Adopt the [DeZog Remote Protocol](https://github.com/maziac/DeZog/blob/main/design/DeZogProtocol.md)
  as the wire protocol rather than defining one. It already treats real ZX Next
  hardware as a first-class remote, bounds memory reads by start and size,
  carries slot and banking state, negotiates versions on init, and expects
  remotes to implement different command subsets.
- [ ] Declare the implemented DZRP command subset per build profile, and confirm
  by interoperability test rather than by reading the specification.
- [ ] Read the command subset implemented by
  [dezogif](https://github.com/maziac/dezogif) before declaring NextTang's. It is the only
  DZRP remote running on real ZX Next hardware, so it is the closest existing precedent for
  what a hardware remote supports, particularly for breakpoints, which the protocol notes
  differ considerably on a real ZXNext.
- [ ] Keep the debug transport alive in a clock domain independent of the
  machine being inspected.
- [ ] Implement distinct CPU-halt and whole-machine-freeze semantics.
- [ ] Expose an explicit instruction-retirement event for reliable single-step.
- [ ] Read registers, NextREGs, MMU mappings, and physical memory safely.
- [ ] Add page-aware execution breakpoints and a bounded breakpoint count.
- [ ] Implement the UART transport on the NextTang side and drive it with the client from
  the [host tooling track](#host-tooling-track) rather than a NextTang-specific tool.
- [ ] Attempt `debug-lite` synthesis and timing closure on both 60K and 138K.

The declared subset should be checked against the conformance suite from the host tooling
track, which by this point has run against remotes this project did not write.

**Exit evidence:** scripted halt, inspect, step, continue, and breakpoint tests
pass without changing the program result when debugging is disabled. A DZRP
client reaches the same results over the transport, with the declared command
subset and the unimplemented commands both recorded.

## Milestone 7: Debug-full and source integration

- [ ] Add read/write watchpoints with explicit CPU/DMA ownership semantics.
- [ ] Add a triggered circular trace containing instruction, physical page,
  memory-write, interrupt, and timing information.
- [ ] Bound trace storage and define deterministic overflow behavior.
- [ ] Identify the Console's actual USB controller and debugger MCU, which the
  board documentation does not name, then evaluate higher-bandwidth transport
  over the documented USB3 device interfaces.
- [ ] Add SLD/source-map loading and page-aware symbol resolution.
- [ ] Reach source-level debugging through existing DZRP clients, primarily
  [DeZog](https://github.com/maziac/DeZog) in VS Code, rather than building a
  source display and stepping interface. The
  [JNext debugger](https://github.com/jorgegv/jnext) becomes a peer speaking the
  same protocol rather than a front end requiring a bespoke backend. The JNext author
  proposed DZRP for the same interoperability reason in
  [jnext#12](https://github.com/jorgegv/jnext/issues/12), where the ZX Basic Studio author
  agreed, so this records a shared direction rather than an assumption about upstream.
- [ ] Run [dezogif_ng](https://github.com/jorgegv/dezogif_ng) on NextTang once the core
  boots. It is ordinary Next software, so it should load like any other, giving two
  independent DZRP remotes for one machine: a guest-side stub and the fabric debug unit.
  They must agree on registers, memory, and MMU state, and a disagreement identifies a
  defect in one of them that is worth a minimal reproduction either way. Loading it at all
  also exercises Multiface, AltROM, and Copper, and it requires core 03.01.10 or newer.
  This is the same in-band and out-of-band pairing JNext is building, so the conformance
  table covers both machines with one shape.
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
| Core integration | Keep MiSTer pinned; disposition NextNano findings; isolate platform dependencies |
| Simulation | Reset, two-port memory, refresh-stall, scanline-buffer, clock-domain, and bus-handshake fixtures |
| Verification | Select small cross-platform Next tests and evidence formats |
| Debugger | DZRP command subset, halt semantics, and host client integration |
| Host tooling | The [host tooling track](#host-tooling-track): DZRP client and conformance suite, no Tang board required |
| USB transport | Identify the onboard USB controller, document its firmware path, and prototype a bounded debug transport |
| PCIe experiment | Track Gowin GT EQ support and test independently; never gate core bring-up |

Coordination happens through the
[NextTang issue tracker](https://github.com/jattree/NextTang/issues). Each task
should name an owner, the hardware/toolchain it needs, and an observable
completion condition.
