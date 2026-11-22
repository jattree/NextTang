# Tang Nano 20K: CPU speed and interrupt timing against a real Next

The Nano 20K keeps the Next's main memory in SDR SDRAM, which cannot answer
as fast as the official board's SRAM. This page records how far the CPU's
timing is from a real Next, measured on the board, and how it was measured.
Board: Tang Nano 20K v3923; core 3.02.05; master clock 28.125 MHz (0.45 %
fast); the HDMI-exact frame (70,312.5 T-states at 3.5 MHz, +3 timing, 50 Hz).

## CPU speed

Method: four loops (64 NOP; 64 LD A,(HL); 64 LD (HL),A; LDIR of 32 bytes),
each run for exactly 25 frames and ended by the frame interrupt, at each CPU
speed, once from main memory and once from bank 7's block RAM. The count of
loop turns against the T-states a frame gives the percentage of full speed.
"Real Next" is JNext 1.3.5's model (one wait state on main-memory reads at
28 MHz, none otherwise); no real Next has run the test.

Main memory, percent of full speed (NOP / read / write / LDIR):

| CPU speed | Before 2026-11-21 | Posted writes (`1402d40`) | With `--word-cache 4` | Real Next |
| --- | --- | --- | --- | --- |
| 3.5 MHz | 100 / 100 / 88 / 96 | 100 / 100 / 100 / 100 | the same | 100 |
| 7 MHz | 100 / 100 / 88 / 96 | 100 / 100 / 100 / 100 | the same | 100 |
| 14 MHz | 67 / 64 / 64 / 72 | 80 / 78 / 87 / 87 | 94 / 96 / 97 / 98 | 100 |
| 28 MHz | 51 / 47 / 47 / 56 | 58 / 54 / 64 / 69 | 73 / 73 / 80 / 84 | 80 / 78 / 87 / 87 |

Bank 7 (block RAM) is exact at 7, 14 and 28 MHz in every column.

What each step did:

- **Posted writes.** A write no longer holds the CPU: it is taken at the
  request and done in the background. Before, every main-memory write cost one
  T-state even at 3.5 MHz.
- **Word cache** (`--word-cache 2` or `4`; 2 is the default since 2026-11-22, 0
  turns it off). The last two or four 4-byte words read are kept; a read of a byte in one of them costs no wait at 14 MHz
  and below and one wait at 28 MHz, the official timing. A read that misses
  still waits about three machine cycles, and sequential code misses once in
  four bytes: that is what is left of the gap.

## Interrupt pulse length

The frame interrupt stays active for 32 T-states (36 in 128K timing). A
NextTang patch stops that count while the board's memory holds the CPU, so
that slow memory cannot hide the pulse. Until `80faa0f` it stopped the count
for every CPU cycle with the memory's wait up, which on this board includes
cycles where the CPU is not delayed at all.

Method ([`firmware/intlen`](../firmware/intlen/intlen.asm)): interrupt
handlers of known length (31, 33, 35 ... 49 T-states from the acknowledge to
the end of RET, in IM 1 with a RAM page at 0x0000); a handler that returns
while the interrupt is still active is entered a second time in the same
frame. Counting which lengths are entered twice gives the pulse length.

| Code, stack and handler in | Until `80faa0f` | From `80faa0f` | Official |
| --- | --- | --- | --- |
| Block RAM (bank 7) | 32 T | 32 T | 32 T |
| Main memory | about 37 T | 32 T | 32 T |

## Running the tests

[`firmware/intlen`](../firmware/intlen/intlen.asm) and
[`firmware/memstress`](../firmware/memstress/memstress.asm) (LDIR, zxnDMA
copy and fill, PUSH and write-then-read over 4 KiB of main memory at each
speed; the correctness check for any change to the memory path) assemble with
`sjasmplus`. Each is loaded and run through the debugger: write the binary at
0x8000, set PC and SP as its header says, run to its `finish` label and read
the results from the addresses the header names.

## Timing closure

With every option on, the Nano image fills 97 to 98 percent of the FPGA, and
whether a build meets timing varies widely between placements of the same
source: of the builds made for these changes, about one in six to nine did.
Place options 3 and 4 are not accepted for this device and route option 1 has
not built. Record the place and route options with any image, and boot-test
it on the board; "timing met" by 0.001 ns is the usual result of a build that
passes.

## The default build (2026-11-22)

`--word-cache 2` is the default. The image in the reference board's flash
(hov2-p1r2, `955f3d6`, all features, place 1, route 2; 20,095 cells, timing met
with 0.035 ns to spare) uses it. Measured on that image, code in main memory
against the same code in block RAM: full speed at 3.5 and 7 MHz, 94 to 98% at
14 MHz and 72 to 84% at 28 MHz. With the debug-link fix of `955f3d6` in the
source, eight placements of the four-entry cache missed timing and so did
every build without a cache; of four placements with two entries one met it.
