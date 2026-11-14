# RZX replay, recording and rewind (planned)

Status: **planned, not implemented** (owner request 2026-11-14). The official Next has
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
