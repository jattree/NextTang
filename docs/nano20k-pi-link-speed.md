# Tang Nano 20K: how fast the Pi Zero can use the debug link

Measured on the reference board (Tang Nano 20K v3923, Pi Zero W on header
pins 25-28) with image hc-p1r2 (boards `06624c3`), 16 blocks of 4,000 bytes
written with A8 and read back with A7 from a Pi program using spidev:

| SPI clock | Writes (A8) | Reads (A7) before `add72be` | Reads (A7) since `add72be` |
| --- | --- | --- | --- |
| 2 MHz | clean | clean | clean |
| 3 MHz | clean | clean | clean |
| 3.5 MHz | clean | fail | clean |
| 4 MHz | clean | fail | clean |
| 4.5 MHz | clean | fail | about 6% of bytes wrong |
| 5-6 MHz | clean | fail | fail |
| 7 MHz | clean | fail | fail |
| 7.5 MHz and up | fail | fail | fail |

So: **reads (and the mailbox polls and status reads that use MISO) at 4 MHz at
most, writes at up to 7 MHz.** A Pi program can set the rate per transfer
(`speed_hz` in `spi_ioc_transfer`) and use a faster rate for writes. Do not probe
for the limit while a program runs: a transfer at a failing rate can damage
the next one.

Why reads were slower: the slave (`rtl/serial/spi_slave.vhd`) samples SCLK
with the 28 MHz machine clock through a synchroniser, and shifted each MISO bit
out at the falling edge it saw, which left less than half an SCLK period
before the Pi samples. Since `add72be` it shifts as soon as it sees the rising
edge, and loads the next byte two clocks after a byte's last bit. In
simulation (`tests/sim/debug/tb_pi_spi_rate.vhd`, with the board's pin
registers) the old slave fails at 3.5 MHz, as on the board, and the new one
passes up to 4.5 MHz; the board's real pin and wire delays take that to 4 MHz.

The FPGA's own SPI master (debug UART link and rewind ring) runs at 3.5 MHz
since `06624c3` (it was 1.75 MHz). With the rewind ring on hc-p1r2, rewinds over
2, 4 and 6 checkpoints took 0.5, 1.1 and 1.1 s, and the session's recording plays
cleanly in Fuse.
