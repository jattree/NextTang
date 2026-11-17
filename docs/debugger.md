# Debugging the Next core

The Next core carries the official ZX Spectrum Next Pi debug interface (core
3.02.04 on, `pi_debug_control`): pause, resume and single-step the CPU, read
and write its registers, main memory, banks 5 and 7 and the NextREGs. NextTang
reaches it over the Console's debug UART and adds hardware breakpoints. The
game's memory is never patched and the debugger costs it no cycles while it
runs.

What is verified, and how, is recorded in the wiki
(`raw/debugger-official-interface-2026-11-02.md`).

## Connection

The debug UART is the external USB-UART adapter on the Console's R14/P14 pins
(the status-line port), 115200 baud. Only one program may hold the port: close
a terminal watching the status lines first.

## Command line

```bash
host/debug/bin/nexttang-debug status
host/debug/bin/nexttang-debug pause          # stops at an instruction boundary, shows registers
host/debug/bin/nexttang-debug step 3
host/debug/bin/nexttang-debug peek 5C00 40   # Z80 address through the MMU
host/debug/bin/nexttang-debug poke 5800 16 16 16
host/debug/bin/nexttang-debug nextreg 07
host/debug/bin/nexttang-debug resume
```

Numbers are hexadecimal; `--port` names another serial device. Banks 5 and 7
live only in the core's block RAM, and the official interface reaches them
only while the CPU is paused, so pause before reading or writing the screen.

## From a Raspberry Pi wired to the slave (Nano 20K with a Pi Zero)

Boards that put the official Pi debug slave on a Pi's GPIO 8 to 11 (the Nano
20K: header pins 25 CE0, 26 MISO, 27 MOSI, 28 SCLK; machine parameter
`PI_SPI_PINS`) need no UART: run the same tool on the Pi with its spidev
device. SPI must be enabled on the Pi (`dtparam=spi=on`).

```bash
host/debug/bin/nexttang-debug --spi /dev/spidev0.0 status
host/debug/bin/nexttang-debug --spi /dev/spidev0.0 pause
```

Mode 0, one transfer per command, 2 MHz by default (`--spi-speed`); the
slave samples SCLK through synchronisers on the 28 MHz machine clock.
Hardware-verified on a Nano 20K with a Pi Zero W (2026-11-14): status,
NextREGs, pause, registers, memory and resume work. 0.5 to 3 MHz read clean
(300 NextREG reads and 5 x 4 KB peeks each); 4 MHz and above return wrong data.
At 2 MHz a NextREG read takes 0.3 ms and memory reads about 160 KB/s inside one
process; each CLI call adds about 1.5 s of Python start-up on a Zero W.

Wiring (Pi physical pin -> Nano 20K FPGA pin): 19 MOSI -> 27, 21 MISO -> 26,
23 SCLK -> 28, 24 CE0 -> 25, and a ground (the Nano's left header from the
USB-C end runs 27, 28, 25, 26, 29, 30). Build with `--pi-pins 1`.

## DeZog in VS Code

Start the bridge, which serves DZRP on port 11000 as CSpect and JNext do:

```bash
PYTHONPATH=host/debug python3 -m nexttang_debug.dzrp
```

DeZog 3.7 (Marketplace) in `launch.json`:

```json
"remoteType": "cspect",
"cspect": { "hostname": "localhost", "port": 11000 }
```

DeZog 3.8 or later:

```json
"remoteType": "dzrp",
"dzrp": { "port": 11000 }
```

Connecting pauses the machine; stopping the session (or a dropped connection)
clears the breakpoints and lets it run.

## Breakpoints

Ten hardware comparators: eight for DeZog's breakpoints and two for its
step-over and step-out. A breakpoint stops the CPU before the instruction at
its address runs, including when a jump, call, return or interrupt lands
there. A breakpoint DeZog gives a bank fires only while that 8K page is mapped
at the address. Conditions and log points are evaluated by DeZog. Watchpoints
and state save/restore are not available on hardware yet.

A board built with fewer comparators must say so: `--breakpoint-slots 2` for the
Nano 20K images. With fewer than four, none are kept back for stepping: DeZog's
breakpoints and its temporary ones share what is free, and a step with none free
is done as one hardware single step (so a step over a CALL goes into it). Without
the option the bridge writes its temporary breakpoints to comparators 8 and 9,
which such a board does not have, and a step never stops (found 2026-11-17 with
OverSpec's probe, review-tools/dzrp_probe.py --place-loop).

## Limits

- Pausing stops the CPU only. Video, sound, timers and the copper carry on,
  and an interrupt due during a pause is missed.
- ROM (MMU page FF) reads as FF through the debugger; the interface has no ROM
  access.
- UART speed bounds bulk transfers (about 7 KB/s for reads).
