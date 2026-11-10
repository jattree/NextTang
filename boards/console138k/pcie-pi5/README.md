# Raspberry Pi 5 over PCIe to the Tang Console 138K

The Tang Console 138K and a Raspberry Pi 5 linked over PCIe at 5 GT/s x1, with
the Pi reading and writing FPGA memory. This page records how to bring the link
up and what has been measured. It is the start of NextTang's Pi 5 platform: the
Console 138K with a Pi 5 is the project's flagship pairing.

Status: **hardware-verified link, register access and bus-master DMA** on one
bench (Console 138K, 30354 1 GB SOM, GW5AST-LV138PG484AC1/I0; Raspberry Pi 5).
The Tang writes into the Pi's RAM at **475 MB/s**, 99.3% of what a Gen2 x1 link
can carry. A Gen3 build also works, at **935 MB/s**, with the Pi at its
unofficial Gen3 setting (see [Gen3](#gen3-8-gts)); Gen2 stays the default. Since 2026-11-09 the link comes up **at boot** with no steps on the
Pi, including from flash and from a cold power-on (one run so far; see below). The NextTang Next core does not
use PCIe yet.

## Why the link failed before

The Pi 5 drives its PCIe reference clock at 54 MHz (its crystal frequency) while
its firmware boots and holds PERST#, for roughly 8 to 15 seconds. It switches to
100 MHz only when the Linux driver starts the port, and stops the clock after a
failed link. Measured with frequency counters on the SerDes quad's clock outputs.

If the GW5AST SerDes was configured before or during that 54 MHz phase, the link
never trains: both ends sit in Polling.Active. A quad POR through
`por_toggle_by_fabric`, or holding the PLLs and lane in power-down until the
clock is a steady 100 MHz, does not recover it. Equalisation was not the cause;
no EQ changes are needed.

## The fix: replay the SerDes boot registers once the clock is right

[`rtl/nt_serdes_reinit.v`](rtl/nt_serdes_reinit.v) measures the reference
clock through the quad. Each time it has been a steady 100 MHz for 1 ms after
being absent or wrong, it writes the PCIe IP's own boot register file
(`serdes.csr`, 179 writes) over the PCIe core's DRP port, then holds the core in
reset for about 10 ms. The link then trains at boot, 0.66 s into the Pi's
kernel. The DRP write handshake matters: hold `drp_wr` with address, data and
`drp_strb = 8'hFF` until `drp_ready` rises (IPUG1024 3.11; `drp_ready` idles
low). A one-cycle write pulse is ignored, which is why an earlier replay
attempt seemed to do nothing.

| Order (2026-11-09) | Without the replay | With it |
| --- | --- | --- |
| Tang configured with no clock or at 54 MHz, then the Pi boots | 0 of 20 | 9 of 9 test design, 3 of 3 this design |
| Same, Tang booting from flash (the power-on case) | not linking | 3 of 3 test design, 2 of 2 this design |
| Cold power-on of both boards, power-up order not recorded | not tested | 1 of 1 (test design) |
| Same reset hold, no replay (control) | 0 of 2 | |

GOWIN's suggested Customized PHY reconfiguration file (IPUG1024E 3.11.2) does
not suit the PCIe hard core: written after the clock settles, it stops even a
good link from training. Details: [sipeed/TangMega-60K-example#1](https://github.com/sipeed/TangMega-60K-example/issues/1).

## Building

Tested with Gowin 1.9.12.03 and Sipeed's TangMega-138K `pcie_dma_demo`, its
SerDes IP regenerated with the PCIe controller at x1 on Q0 lane 0, Q0 REFCLK0 at
100 MHz, MSI and DRP enabled.

1. `tools/patch_serdes.py src/serdes/serdes.v` adds the status and clock taps
   (`nt_probe`, `nt_probe2`, `nt_clk`) that the top level uses.
2. `tools/csr_rom.py src/serdes/serdes.csr > src/include/nt_serdes_reinit_rom.vh`
   turns the IP's boot register file into the replay list. Regenerate it
   whenever the IP is regenerated.
3. Use `rtl/top_pcie_dma.v` as `src/top.v` and add the other `rtl/` files.
4. Place option 1, route option 1 (`set_option -place_option 1`,
   `set_option -route_option 1`). This closes 100 MHz with margin (TLP clock
   100.7 MHz); place option 2 missed by 2 ns and corrupted DMA data.

## Gen3 (8 GT/s)

Sipeed's Gen2 and Gen3 demos differ only in the SerDes register file, so Gen3
needs no new IP. [`tools/gen3_csr.py`](tools/gen3_csr.py) makes a Gen3 x1
`serdes.csr` from GOWIN's `pcie_gen3_x1.csr` template (in the IDE's
`ipcore/SERDES_IP/IPlib/PCIE/csrDoc/`) with the edits Sipeed's Gen3 file carries:

1. `tools/gen3_csr.py .../csrDoc/pcie_gen3_x1.csr > src/serdes/serdes.csr`
2. `tools/csr_rom.py src/serdes/serdes.csr > src/include/nt_serdes_reinit_rom.vh`
   (213 writes instead of 179).
3. Build as above, with `set_csr src/serdes/serdes.csr`. Timing closed at
   100.2 MHz, with little margin.

On the Pi, `dtparam=pciex1_gen=3` in `config.txt`. Raspberry Pi does not
officially support Gen3 on the Pi 5.

| Test (2026-11-10, same bench and cable) | Result |
| --- | --- |
| Tang configured with REFCLK off, then the Pi boots | link up at boot, 8.0 GT/s x1, 4 of 4 |
| Same, control build (reset hold, no replay) | link down, 2 of 2 at boot and 6 of 6 rebinds |
| Tang loaded from flash with REFCLK off, then the Pi boots | 2 of 2 |
| DMA ladder from SRAM and from flash | passed, AER clear |

| Payload per packet | Gen3 x1 (Tang / Pi) | Gen2 x1 (Tang / Pi) |
| --- | --- | --- |
| 128 B | 823.0 / 822.8 MB/s | 417.8 / 417.7 MB/s |
| 256 B | 893.8 / 893.2 MB/s | 454.0 / 453.8 MB/s |
| 512 B | 934.7 / 933.9 MB/s | 475.1 / 474.7 MB/s |

Once, straight after an unbind, reload from flash and rebind, the driver read
all ones from BAR2 and refused to load; three later rebinds and every clean boot
were fine. Not yet tested at Gen3: a long soak, a cold power-on. NextTang's
debug traffic needs nowhere near Gen2's bandwidth, so Gen2, the Pi 5's
supported speed, stays the default.

## Manual recipe (designs without the replay)

Pi 5 with `dtparam=pciex1` (and `dtparam=pciex1_gen=2` for 5 GT/s). The Tang
powered and programmed through its MCU USB-C only (powering it through the FPGA
port at the same time stopped its USB debugger enumerating on the host).

1. Boot the Pi. Its external port reports "link down".
2. `echo 1000110000.pcie | sudo tee /sys/bus/platform/drivers/brcm-pcie/unbind`
3. Configure (or reconfigure) the Tang's FPGA, for example into SRAM:
   `openFPGALoader --board tangconsole --write-sram --freq 6000000 design.fs`
4. `echo 1000110000.pcie | sudo tee /sys/bus/platform/drivers/brcm-pcie/bind`
   The link comes up: 2.5 GT/s with the Pi at Gen1, 5.0 GT/s x1 at Gen2.
5. With no driver bound, enable the endpoint's memory space before touching a
   BAR: `echo 1 | sudo tee /sys/bus/pci/devices/0001:01:00.0/enable`
   Without this the BARs stay disabled and every read returns `FFFFFFFF`.

Step 5 applies with the replay too. Never read a BAR offset the FPGA design
does not answer: an unanswered read once crashed the Pi, which rebooted itself.

[`pi/nexttang-pcie-up`](pi/nexttang-pcie-up) is a draft of a Pi service that
runs these steps, with the Tang's MCU USB on the Pi. Designs with the replay do
not need it.

## Results

| Date | Cable | Link | Test | Result |
| --- | --- | --- | --- | --- |
| 2026-11-02 | jumper-wired bench | 5 GT/s x1 | 20,000 rounds of 16 random 32-bit writes and reads | 0 mismatches, AER clear |
| 2026-11-06 | 52Pi PCIe 3.0 x1 FPC | 5 GT/s x1, first try | 1,720,001 rounds (27.5M writes and 27.5M reads) | 0 mismatches, AER clear on root port and endpoint |
| 2026-11-06 | 52Pi PCIe 3.0 x1 FPC | 5 GT/s x1 | DMA ladder to 16 MiB x 100 | 4.8 GiB exact, 475 MB/s, AER clear |
| 2026-11-09 | 52Pi PCIe 3.0 x1 FPC | 5 GT/s x1, at boot | DMA ladder with the SerDes replay, from SRAM and from flash | passed both, 475 MB/s, AER clear |
| 2026-11-10 | 52Pi PCIe 3.0 x1 FPC | 8 GT/s x1, at boot | Gen3 build, DMA ladder from SRAM and from flash | passed both, 935 MB/s, AER clear |

A read from the Pi to the FPGA takes about 1.35 us round trip, so single-word
reads move only about 3 MB/s: the CPU waits for each completion. Bulk data
therefore goes the other way, with the Tang as bus master.

## DMA: the Tang writes into Pi memory

2026-11-06, design `dma-v3` (meets 100 MHz). The Pi's driver allocates a buffer,
works out its bus address and programs the Tang's write engine (BAR2
0x40-0x7F): base, length, payload size, pattern, GO. The Tang streams posted
memory writes and reports cycles, bytes and packets.

| Test | Result |
| --- | --- |
| Ladder 64 B, 4 KiB, 64 KiB, 1 MiB, then 16 MiB x 100 | all PASS, 4.8 GiB checked byte for byte |
| Guard areas (4 KiB before, 64 KiB after the buffer) | untouched |
| AER, root port and endpoint | clear after every step |
| Deliberately bad GO requests | refused, 0 bytes sent |

| Payload per packet | Measured on the Tang | Measured on the Pi | Gen2 x1 ceiling |
| --- | --- | --- | --- |
| 128 B | 417.8 MB/s | 417.7 MB/s | 421 MB/s |
| 256 B | 454.0 MB/s | 453.8 MB/s | 457 MB/s |
| 512 B | 475.1 MB/s | 474.7 MB/s | 478 MB/s |

The link is the limit: each packet carries 24 bytes of overhead, and the engine
spends most of its time waiting for the Pi to grant buffer credit.

Safety is enforced in the FPGA, not only by the driver: lengths 4 B to 16 MiB in
multiples of 4, payloads 64 to 512 bytes, every packet clamped to the window the
Pi gave and never across a 4 KiB boundary, parameters locked while busy, ABORT,
and nothing in the design can issue reads to the host.

## Files

- `rtl/nt_bar_completer.v`: one-DW BAR2 completer (16 words) for the Gowin
  256-bit transaction-layer interface.
- `rtl/nt_dma_writer.v`: the bus-master write engine.
- `rtl/nt_tl_tx_mux.v`: packet-locked transmit mux.
- `rtl/ltssm_uart3.v`: LTSSM and SerDes status on the Console's status UART.
- `rtl/nt_serdes_reinit.v`: the SerDes boot-register replay described above.
- `tools/csr_rom.py`, `tools/patch_serdes.py`: build helpers (see Building).
- `tools/gen3_csr.py`: the Gen3 x1 `serdes.csr` from GOWIN's template (see Gen3).
- `rtl/top_pcie_dma.v`: top level of Sipeed's TangMega-138K `pcie_dma_demo`
  (Apache-2.0) with the NextTang changes marked. It needs the rest of that demo
  (PLL, SerDes, PCIe IP), which is not in this repository; the demo's own TLP
  logic is cut off from the transmitter because its completions were not
  accepted by the Pi. Gowin IP and bitstreams stay out of Git.
- `sim/run.sh`: Icarus Verilog simulation of completer, writer and mux with a
  root-complex model (ladder sizes, 4 KiB splits, 64-bit addresses, refusals,
  backpressure, ABORT, 16 MiB), and of the SerDes replay with a DRP model and a
  synthetic write list (`sim/reinit_test.csr`): no replay at 54 MHz, one per
  settle, in order, write held until acknowledged, again after a dropout.
- `pi/ntdma/`: the Pi kernel module (GPL-2.0), its test program and the ladder,
  AER and refusal scripts. Build on the Pi with its kernel headers installed.
- `pi/bar-soak.py`: the register soak test.

## Board notes

- J4 pins 14 and 15 are swapped compared with the Raspberry Pi connector
  standard (CLKREQ#/WAKE# against DET_WAKE/CLKREQ_N). It did not affect the link;
  the design holds the FPGA pin reaching the Pi's CLKREQ_N low.
- In the demo's `top.v`, `rstn` is declared twice. Gowin 1.9.12.03 ignores the
  second declaration, so PERST# does not reset the demo's TLP logic.

Upstream issue: [sipeed/TangMega-60K-example#1](https://github.com/sipeed/TangMega-60K-example/issues/1).
