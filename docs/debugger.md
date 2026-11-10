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

Mode 0, one transfer per command, 500 kHz by default (`--spi-speed`); the
slave samples SCLK through synchronisers on the 28 MHz machine clock.
Not yet tried on hardware.

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

## Limits

- Pausing stops the CPU only. Video, sound, timers and the copper carry on,
  and an interrupt due during a pause is missed.
- ROM (MMU page FF) reads as FF through the debugger; the interface has no ROM
  access.
- UART speed bounds bulk transfers (about 7 KB/s for reads).
