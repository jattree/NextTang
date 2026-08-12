# Adjacent Tang project evidence

This is a dated review of related Tang FPGA projects that may inform NextTang.
Each result applies only to the named upstream commit, tool version and target.
No reviewed source or generated vendor output has been imported into NextTang,
and none of these results is a NextTang build or hardware result.

## Reviewed snapshots

| Project | Reviewed identity | Useful evidence | Local result |
| --- | --- | --- | --- |
| [NextNano](https://github.com/RetroSilicon/NextNano) | [`ba1d834`](https://github.com/RetroSilicon/NextNano/commit/ba1d834fb672c75a9482233557ae776602b1b243) | Gowin clock-enable, memory CDC, reset-epoch, sticky-diagnostic and timing-report patterns | Source reviewed only |
| [MSXimus](https://github.com/Papipapito/MSXimus) | [`v2.1.2`](https://github.com/Papipapito/MSXimus/tree/56543fe071cbb9fab0c310f77906521d50075f0e), commit `56543fe` | Candidate Console 60K clock, HDMI, SD, flash, BL616 and board-control mappings | Synthesis completed, but the full build failed before place-and-route; no bitstream |
| [Tang Mega 138K FPGA projects](https://github.com/vdalex/tangmega-138k-fpga-projects) | [`7c17183`](https://github.com/vdalex/tangmega-138k-fpga-projects/tree/7c17183b7978238023a49c8d29220337142d4133) | 50 MHz input and 150/750 MHz DVI path using `OSER10` and differential outputs | Five bitstreams generated; one project missed its 150 MHz setup constraint |
| [MSXnano](https://github.com/Papipapito/MSXnano) | [`v1.9`](https://github.com/Papipapito/MSXnano/tree/ce46ef93b3a284334b69c73636a0047b890d8c96), commit `ce46ef9` | Nano 20K shell, BL616 FPGA Companion boundary and focused regressions | Two regressions passed; a compatibility-adjusted build generated a bitstream with 36 setup and 12 hold violations |
| [MSXgoauldSD_usbkb](https://github.com/Papipapito/MSXgoauldSD_usbkb) | [`15f1a7f`](https://github.com/Papipapito/MSXgoauldSD_usbkb/tree/15f1a7fc697129265745e3de8a7d7acca102b945) | External RP2040 USB-input boundary and shared MSXnano lineage | Clean FPGA build failed because four required Verilog files are absent; `gw_sh` still returned zero |

The local builds used GOWIN EDA Standard `V1.9.12.03`. Simulation checks used
Icarus Verilog and Verilator `5.020` where applicable.

## What the reviews answer

The vdalex projects establish that the installed vendor flow can synthesize,
place, route and generate bitstreams for substantial pure-Verilog
`GW5AST-138C` designs. They also provide a useful DVI bring-up shape. Their
constraints target the bare Tang Mega 138K, not the Tang Console carrier, so
the pins cannot be transferred until the exact Console board is inspected.

MSXimus provides the best candidate Console 60K constraint study found so far.
Its active design uses the Console's external SDR SDRAM module and its DDR3
wrapper is unfinished. It does not solve the Console 138K buffered-DDR3 path.

NextNano, MSXnano and Goa'uld provide companion-controller, USB-input and board
shell patterns. These are useful at platform boundaries. They do not identify
the Tang Console's high-speed USB controller or establish Console behaviour.

The build attempts answer a separate process question: a zero tool exit status
or an existing `.fs` file is not sufficient evidence of success. Goa'uld logged
missing-source errors, returned zero and produced no fresh bitstream while its
repository contained older generated output. MSXnano generated a fresh
bitstream but failed timing. Future NextTang board drivers must therefore use
clean outputs, inspect tool logs, require fresh reports and artefacts, and reject
violated required timing constraints.

## Licence and reuse boundaries

The vdalex repository has no licence grant and no provenance notice for its
shared DVI/TMDS block. NextTang will not copy its source or constraints.
MSXimus has a GPLv3 root but includes an active V9968 core under non-commercial
terms and other component licences. MSXnano and Goa'uld also contain multiple
component and payload boundaries. Any reuse still requires a per-file audit.

The current disposition is to study or independently reimplement narrow board
shells, tests, reset sequencing, clocking and interface patterns. MiSTer ZXNext
remains the pinned core baseline.

## Questions still open

- Exact Tang Console 138K product, SOM, PCB and B/C silicon revision.
- Whether bare Tang Mega 138K constraints match the Console carrier.
- NextTang synthesis, resource fit and timing closure on either Console.
- Buffered onboard-DDR3 integration on the 138K.
- The Console USB debug path and measured throughput.
- PCIe stability against a Raspberry Pi 5.
- A complete Console 60K build and hardware result.

These questions remain open until the relevant exact-board build or hardware
evidence exists.
