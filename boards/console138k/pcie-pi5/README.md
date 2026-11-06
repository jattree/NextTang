# Raspberry Pi 5 over PCIe to the Tang Console 138K

The Tang Console 138K and a Raspberry Pi 5 linked over PCIe at 5 GT/s x1, with
the Pi reading and writing FPGA memory. This page records how to bring the link
up and what has been measured. It is the start of NextTang's Pi 5 platform: the
Console 138K with a Pi 5 is the project's flagship pairing.

Status: **hardware-verified link and register access** on one bench (Console
138K, 30354 1 GB SOM, GW5AST-LV138PG484AC1/I0; Raspberry Pi 5). The NextTang
Next core does not use PCIe yet. Bus-master DMA from the Tang is being tested.

## Why the link failed before

The Pi 5 drives its PCIe reference clock at 54 MHz (its crystal frequency) while
its firmware boots and holds PERST#, for roughly 8 to 15 seconds. It switches to
100 MHz only when the Linux driver starts the port, and stops the clock after a
failed link. Measured with frequency counters on the SerDes quad's clock outputs.

If the GW5AST SerDes was configured before or during that 54 MHz phase, the link
never trains: both ends sit in Polling.Active. Nothing from inside the fabric
recovers it (a quad POR through `por_toggle_by_fabric`, replaying the SerDes
registers over DRP, both, or holding the PLLs and lane in power-down until the
clock is a steady 100 MHz). Only a full FPGA reconfiguration clears it.
Equalisation was not the cause; no EQ changes are needed.

## Recipe

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

Never read a BAR offset the FPGA design does not answer: an unanswered read
once crashed the Pi, which rebooted itself.

[`pi/nexttang-pcie-up`](pi/nexttang-pcie-up) is a draft of a Pi service that
runs these steps, with the Tang's MCU USB on the Pi. It is not finished or
tested end to end.

## Results

| Date | Cable | Link | Test | Result |
| --- | --- | --- | --- | --- |
| 2026-11-02 | jumper-wired bench | 5 GT/s x1 | 20,000 rounds of 16 random 32-bit writes and reads | 0 mismatches, AER clear |
| 2026-11-06 | 52Pi PCIe 3.0 x1 FPC | 5 GT/s x1, first try | 1,720,001 rounds (27.5M writes and 27.5M reads) | 0 mismatches, AER clear on root port and endpoint |

A read from the Pi to the FPGA takes about 1.35 us round trip, so single-word
reads move only about 3 MB/s: the CPU waits for each completion. Writes are
posted and much faster. Bulk transfers will use bus-master DMA from the Tang
into Pi memory instead.

The FPGA side is Sipeed's TangMega-138K `pcie_dma_demo` (Apache-2.0) with a small
NextTang BAR2 completer, because the demo's own completions were not accepted
by the Pi (completion timeout). The completer's sources will be added here once
the rebuilt, hardware-checked version is final; the Gowin PCIe IP and
bitstreams stay out of this repository.

`pi/bar-soak.py` is the soak test: random values into the completer's 16
words, read back, for N rounds (`sudo python3 bar-soak.py 200000`).

## Board notes

- J4 pins 14 and 15 are swapped compared with the Raspberry Pi connector
  standard (CLKREQ#/WAKE# against DET_WAKE/CLKREQ_N). It did not affect the link;
  the design holds the FPGA pin reaching the Pi's CLKREQ_N low.
- In the demo's `top.v`, `rstn` is declared twice. Gowin 1.9.12.03 ignores the
  second declaration, so PERST# does not reset the demo's TLP logic.

Upstream issue: [sipeed/TangMega-60K-example#1](https://github.com/sipeed/TangMega-60K-example/issues/1).
