# RZX replay, recording and rewind (planned)

Status: **recorder and player simulation-verified** (owner request 2026-11-14). The
input recorder (`rtl/debug/nexttang_rzx_logger.v`) and player
(`rtl/debug/nexttang_rzx_player.vhd`) are checked in simulation against the real core;
neither is in any build yet, and nothing has run on hardware. The official Next has
no input recording, no RZX support and no rewind; NextZXOS 26.11 loads SNA/Z80/SNX/NEX
snapshots and the NMI menu can save state by hand. This is a NextTang addition, inside
the Next core, for the 138K and, where it fits, the Nano 20K. cpcnext plans the same
idea for the CPC (WinAPE SNR); the shared model below keeps the two aligned.

## Shared model (NextTang and cpcnext)

A session is **a starting snapshot plus a log of everything the CPU read from outside
itself, frame by frame**. Replaying the log from the snapshot reproduces the run
exactly, whatever the timing of the machine replaying it. Rewind is **a ring of
periodic checkpoints plus that same log**: to go back to any frame, restore the
checkpoint before it and replay the log forward to the frame. One mechanism serves
recording, playback, attract loops, take-over (stop replaying, hand the keys to the
player) and rewind.

## Format: RZX

RZX (Ramsoft's published format) holds a snapshot block (.Z80 or .SZX inside), then
input recording blocks: per frame, the number of instruction fetches before the
interrupt and the bytes every IN read returned. Emulators such as Fuse play it, and the
RZX Archive holds thousands of full-game recordings. Implement from the published
specification only; no emulator code is reused.

- **Profile 1, classic:** 48K, 128K and +2A/+3 machines, ULA frame interrupt only, Next
  extras off. Recordings interoperate both ways with Fuse: record on NextTang, play in
  an emulator; play RZX Archive runs on NextTang.
- **Profile 2, Next:** line interrupts, CTC, hardware IM2, DMA and copper break RZX's
  one-interrupt-per-frame model, and a .Z80 cannot hold a Next's state. NextTang adds
  its own blocks (RZX readers skip unknown block IDs): a full Next state snapshot and
  interrupt events with their source. These files play only on NextTang.

## Hardware pieces in the core

1. **Fetch counter and IN logger (record).** Count M1 fetches since the last accepted
   interrupt; capture the data byte of every I/O read (not interrupt acknowledge).
   RZX's counter follows the R register: 1 per opcode fetch, 2 for a prefixed
   instruction, interrupt acknowledge not counted (RZX format v0.13, World of Spectrum
   mirror: ftpmirror.infania.net/sites/www.worldofspectrum.org/RZXformat.html). That is
   the count of the Z80's M1 cycles less the acknowledge cycle. Frames are a WORD fetch
   count, a WORD IN count (65535 = same reads as the previous frame) and the IN bytes,
   optionally zlib-compressed.
   A small FIFO drains into spare SDRAM (the Next uses 2 MB; the Nano has 8 MB, the
   138K more). Floating-bus and keyboard reads are just IN values, so they are covered.
2. **Player.** While playing, IN data comes from the log instead of the ports, and the
   interrupt fires when the frame's fetch count is reached rather than from the ULA.
   A frame whose IN count disagrees at its interrupt is a desync: stop visibly and keep
   the last good picture.
3. **Snapshot capture and restore.** The debugger path already pauses the CPU and reads
   and sets registers, memory, bank 5/7 and NextREGs (docs/debugger.md). Profile 1
   needs CPU state, RAM, paging (7FFD/1FFD), border and AY registers; AY register
   readback is the one known gap. Profile 2 adds palettes, sprite, tilemap and copper
   RAM, DMA and CTC state.
4. **Rewind ring.** A dirty bit per 256-byte block of the 2 MB (8,192 bits, one block
   RAM) marks what the CPU or DMA wrote. At each checkpoint (about once a second, at a
   frame interrupt) a copy engine on the debug memory port saves registers and only the
   dirty blocks into an SDRAM ring. Rewind = restore + replay forward from the log.

## Control and files

File I/O stays with NextZXOS (it owns the SD card): dot commands such as `.RZXREC`,
`.RZXPLAY` and `.RZXSTOP` move the log between SDRAM and the card and drive the
hardware through NextTang NextREGs; later, entries in the NMI menu and a rewind key.
On boards with a Pi (Pi Zero on the Nano, Pi 5 on the 138K) the host tools can do the
same through the debug interface.

## Progress

- **Input recorder, simulation-verified (2026-11-14).** `rtl/debug/nexttang_rzx_logger.v`
  watches the CPU's own M1, IORQ and RD and its input register (the core's existing
  `o_SPEC256_*` exports, so the core itself is unchanged) and streams IN bytes and
  frame ends as 9-bit words; `tools/rzx.py`'s `frames_from_logger` turns them into RZX
  frames. `tests/test_rzx_logger.py` covers the module on its own (random frames with
  back-pressure, 28 MHz timing, saturation, overflow). `tests/sim/zxnext/run_rzx_check.sh`
  runs the whole core on the clock test ROM (all four CPU speeds, frame interrupts from
  HALT, keyboard and port reads) for 4.5 million cycles: 6 frames, 219,603 fetches and
  33 IN reads, every frame's fetch count agreeing with the CPU's R register, and the
  recorder's output identical to the frames worked out from the bus. Hiding a single
  fetch makes the R check fail.
- **Player, simulation-verified (2026-11-14).** `rtl/debug/nexttang_rzx_player.vhd` takes
  RZX frames as a byte stream. While it plays, the core (three NextTang inputs on
  `zxnext`: `i_RZX_PLAY`, `i_RZX_INT`, `i_RZX_IN_DATA`) takes every CPU I/O read's byte
  from it and its maskable interrupt from it alone; it raises the interrupt during each
  frame's last fetch and checks every frame at the acknowledge. `run_rzx_check.sh` now
  records the clock test ROM, then runs it three more times: with every key down and EAR
  high and no playback, the CPU reads different bytes (keyboard `e0` instead of `bf`);
  with the same changed inputs played from the recording, all 6 frames are identical to
  the recording (fetch counts, R and every IN byte) and the player reports no desync;
  with one IN byte left out of frame 2, the player reports a desync in frame 2 and hands
  the core back its live inputs. A fetch count off by one is not caught on this ROM,
  which waits for every interrupt in HALT, where one fetch more or less changes nothing.
- 2026-11-15, Nano 20K recorder, hardware-verified: `build_zxnext.sh --rzx 1` adds the
  recorder and a UART sender (`rtl/debug/nexttang_rzx_uart.v`) to the debug UART; `Z`
  arms it (recording starts at the next CPU resume), `z` stops it. `host/rzx_capture.py`
  pauses the CPU, reads registers and the 48K of RAM through the debugger into a .z80
  snapshot, records, and writes the .rzx. A 10 s recording made on the board in 48K BASIC
  (typing a two-line program and RUN; 504 frames, 4,027 IN values) plays to its end in
  Fuse 1.6.0 as a 48K Spectrum, with Fuse's own 48K ROM and with the Next's 48K ROM.
  Three things were needed for that:
  - The recorder also ends a frame when the CPU declines an interrupt (interrupts
    disabled), as emulators count a frame per ULA frame; before this a frame's fetch
    count ran on over several frames and saturated. The frame ends at the start of the
    first whole instruction, never after a DD, FD, ED or CB prefix, at which the CPU
    looked at the interrupt and did not take it, which is where an emulator tries its
    interrupt on replay. A second recording, of a program with `BEEP 1,0` (705 frames, 49
    of them in a row with interrupts off), also plays to its end in Fuse with both ROMs.
  - The debugger's interrupt-mode readout now reports the CPU's mode (`IStatus`). The
    official 3.02.05 debug readout reports the decoder's request (`IMode`), which reads
    as IM 2 almost always, and a snapshot saved with IM 2 goes out of step at the first
    interrupts.
  - NextZXOS leaves divMMC automapping on in 48K BASIC (entry points 0x0008 and 0x0038),
    so every interrupt runs code a 48K Spectrum does not have; the capture tool turns it
    off (NextREG 0x0A bit 4) for the recording and puts it back.
  Only 48K programs so far. The board cannot yet play a recording (the player is in
  simulation only), and the player does not yet handle frames that end without an
  acknowledge.
- Next: the same changes in the main branch, the player on the Nano 20K, then the 138K.

## Order

1. 138K: logger + host-side snapshot over the debugger; write an .rzx; it plays in Fuse.
2. 138K: player; RZX Archive recordings play on NextTang (Profile 1).
3. Rewind ring with dirty-block checkpoints.
4. Profile 2 (Next mode) blocks.
5. Nano 20K: the logger and player are small; the rewind copy engine depends on what
   is left (logic 83 %, block RAM 40 of 46 today).

Acceptance at each step: a recording replayed twice gives identical frames and audio;
a deliberately wrong snapshot or ROM desyncs and stops; recordings made by an emulator
play to their end on the board.
