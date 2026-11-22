# Tang Nano 20K: the USB chip (BL616) and its firmware

The Tang Nano 20K has a second chip beside the FPGA, a Bouffalo BL616. It owns
the board's USB-C socket and runs two separate programs from its own flash:

| Flash address | Program | What it does |
| --- | --- | --- |
| `0x0` | Sipeed's FPGA Partner (encrypted, from the factory) | The USB debugger a PC sees (`0403:6010`, "SIPEED USB Debugger"): loads bitstreams into the FPGA and carries the USB serial port. Decides at power-up whether a PC is attached. |
| `0x40000` | FPGA-Companion | Runs when no PC is attached, for example with the board on a USB-C splitter and a charger: it is then a USB host and passes a keyboard, mouse and joypad to the FPGA over SPI. |

NextTang's Nano image talks to the FPGA-Companion when built with
`--companion 1` (see [`boards/nano20k/build_zxnext.sh`](../boards/nano20k/build_zxnext.sh)).
NextTang never writes the FPGA Partner at `0x0`.

## What is on the reference board

Board: Tang Nano 20K, revision **v3923**. The revision matters: v3921 and v3923
connect the BL616's SPI to different pins (MISO GPIO 2 against 30, MOSI GPIO 3
against 27), so each needs its own FPGA-Companion build.

| | Before 2026-11-21 | Since 2026-11-21 |
| --- | --- | --- |
| Program at `0x40000` | NextNano v1.0 release file `fpga_companion_tn20k_3923.bin` | FPGA-Companion built here from source |
| Source | [RetroSilicon/NextNano releases](https://github.com/RetroSilicon/NextNano/releases) | [MiSTle-Dev/FPGA-Companion](https://github.com/MiSTle-Dev/FPGA-Companion) at commit [`c6eb3d6`](https://github.com/MiSTle-Dev/FPGA-Companion/commit/c6eb3d68eb6cf2681a8d11aeec672cb1865157cc) (`1.4.35-1-gc6eb3d6`, 2026-11-14), unmodified |
| Size | 687,072 bytes | 750,160 bytes |
| SHA-256 | `110fe7b31d3430ec030bcb62841f39d20ff30913ac2ab47f9e684e02b2d39319` | `51a12c8eb73f9d8f94bb478576327145da79e7383203b16ba7a9505a347fd716` |

Why it was changed: commit `c6eb3d6` sets the HID interrupt transfer timeout
to 0 in `src/bl616/mcu_hw.c`. Release 1.4.35 was tagged a few hours earlier
and does not contain it, and there are no build artefacts for the commit, so
the file was built here. The change was made to help a USB mouse that did not
work with the earlier file.

The FPGA-Companion is Apache-2.0 licensed. Its binary is not kept in this
repository; build it as below.

### Evidence, and what is not yet tested

- The file that was on the chip was read back first and matched the NextNano
  v1.0 release file byte for byte.
- After the write, the chip's own SHA-256 of the new program matched the file,
  and a full read-back showed the FPGA Partner region (`0x0` to `0x40000`)
  unchanged.
- After a normal power-up the board enumerates as the SIPEED USB Debugger, the
  FPGA is detected over JTAG, and the NextTang image boots from flash.
- Tested with the new file on 2026-11-22, the board powered through a USB-C
  splitter and running image hov2-p1r2 (boards `955f3d6`, `--companion 1`):
  - a USB keyboard: letters type in NextBASIC; a probe program reading the
    keyboard rows saw Ctrl and Alt (left and right) as SYMBOL SHIFT, Shift as
    CAPS SHIFT and Ctrl+P as SYMBOL SHIFT with P, which NextBASIC prints as `"`;
  - a Trust USB mouse, which gave nothing with the earlier file: a probe
    program adding up the Kempston mouse ports' movement saw about 500 to 700
    counts for a slow 5 cm stroke in each of the four directions with the
    right sign, +531 and -1080 for fast flicks right and left, the left, right
    and middle buttons, and the wheel nibble changing.
- **Not yet tested with the new file:** a joypad, and a keyboard and mouse
  together on a hub.

## Building the FPGA-Companion

Following the project's own `src/bl616/README.md`:

- Toolchain: GCC RISC-V 14.3.0 from the
  [bouffalolab toolchain release](https://github.com/bouffalolab/toolchain/releases).
- SDK: [bouffalolab/bouffalo_sdk](https://github.com/bouffalolab/bouffalo_sdk)
  (used here at `eba87edc`, 2026-11-06).

```shell
git clone https://github.com/MiSTle-Dev/FPGA-Companion.git
cd FPGA-Companion && git checkout c6eb3d6 && cd src/bl616
make clean
BL_SDK_BASE="$HOME/bouffalo_sdk" make TANG_BOARD=nano20k_v3923
# result: build/build_out/fpga_companion_bl616.bin
```

Use `TANG_BOARD=nano20k` for a v3921 board.

## Updating the chip

1. Unplug the USB-C cable. Hold the board's **UPDATE** button, plug the cable
   into the PC, release. The chip now appears as `349b:6160` "Bouffalo CDC
   DEMO" with a serial port (`/dev/ttyACM0` on Linux; it may need read/write
   permission for your user).
2. Back up the flash with the SDK's flashing tool
   (`tools/bflb_tools/bouffalo_flash_cube/BLFlashCommand-ubuntu`):

   ```shell
   BLFlashCommand-ubuntu --interface=uart --baudrate=2000000 --port=/dev/ttyACM0 \
       --chipname=bl616 --flash --read --start=0x0 --len=0x100000 --file=backup.bin
   ```

3. Write the FPGA-Companion at `0x40000` only. The tool takes a small
   configuration file; give the firmware's full path:

   ```ini
   [cfg]
   erase = 1
   skip_mode = 0x0, 0x0
   boot2_isp_mode = 0

   [custom]
   filedir = /full/path/to/fpga_companion_bl616.bin
   address = 0x40000
   ```

   ```shell
   BLFlashCommand-ubuntu --interface=uart --baudrate=2000000 --port=/dev/ttyACM0 \
       --chipname=bl616 --cpu_id= --config flash.ini
   ```

   The tool prints the SHA-256 it computed and the one the chip reports; they
   must match.
4. Unplug and plug the cable back in without the button.

If the board is left in "Bouffalo CDC" mode or the FPGA-Companion stays
silent, write a file that matches the board revision again in the same way;
the NextNano release files are a known-good fallback. Do not write to `0x0`.
