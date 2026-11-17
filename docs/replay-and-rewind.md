# RZX replay, recording and rewind

Status: **recording and playback hardware-verified on the Nano 20K** for 48K programs, playback also for 128K, +2 and +3,
and **rewind** for 48K programs, by replay from the PC and from **checkpoints kept on the board**
(the rewind ring; image ringH-p1r2 meets timing)
(owner request 2026-11-14; results under Progress). The input recorder
(`rtl/debug/nexttang_rzx_logger.v`) and player (`rtl/debug/nexttang_rzx_player.vhd`)
are in the Nano 20K build as an option, fed over the debug UART by host tools. Not
done: Next-mode recordings, recordings on the SD card, and the 138K. The official Next has
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

   Worked out on 2026-11-16 (the tracker exists and is measured; the rest is design):

   - **Store: a copy plus undo records**, not a chain of saved blocks. Saving only
     the blocks written since the last checkpoint cannot be undone once the older
     checkpoints that held a block's earlier content have left the ring. So spare
     memory holds a full copy of the 2 MB as of the last checkpoint, and each
     checkpoint writes, for every dirty block, the copy's old content into the ring
     (an undo record: what the block held at the checkpoint before) and then brings
     the copy up to date. Going back to checkpoint k: put the copy into the live
     memory for the blocks dirty now, then apply the undo records of the later
     checkpoints, newest first, to both. On the Nano's 8 MB: 2 MB live, 2 MB copy,
     4 MB of ring (about 16,000 undo records; at the 41 blocks a second measured,
     several minutes of history). The SDRAM service addresses only the Next's 2 MB
     today; the copy engine needs the rest of the die on a port of its own or on
     port C through a mux.
   - **Banks 5 and 7.** The core keeps bank 5 and the first half of bank 7 only in
     block RAM (the screen and the 48K system variables live there), reached by the
     debug slave's own interface inside the core (`bram_debug_*`). The copy engine
     must read and write those three 8K pages that way, so the core needs a second,
     fabric-side way in beside the slave's.
   - **CPU registers** have to be captured on the board: while a recording runs the
     recorder owns the UART's transmit line, so a host cannot read them. That is a
     fabric-side reader on the CPU's debug register port, beside the slave's.
   - **A checkpoint need not wait for a frame's end.** Stop the CPU anywhere and note
     the recorder's frame number and how many fetches and port reads the frame under
     way has had. To resume a replay from there the host gives the player a first
     frame shortened by those counts; the player needs no change. (The same idea as
     the hand-over from replay to recording, the other way round.)
   - **Cost.** Through a byte port each dirty block is 1,024 accesses (old copy out
     to the ring, live into the copy). At four or five machine clocks an access, 41
     blocks is about 7 ms with the CPU stopped, once a second. Unmeasured.

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
- 2026-11-15, Nano 20K player, hardware-verified: `build_zxnext.sh --rzx 2` (or 3 with
  the recorder) adds the player and a UART link (`rtl/debug/nexttang_rzx_play_link.v`):
  `P` and up to 255 bytes arm it while the CPU is stopped, playing starts at the resume,
  and the rest of the recording follows on the UART into a 1024-byte buffer while the
  board reports each frame end. `host/rzx_play.py` writes the recording's snapshot into
  RAM and the CPU through the debugger and sends the frames. On the board, from a
  cleared 48K BASIC screen, the BEEP recording replays in full (705 of 705 frames, no
  desync, five runs): the program is typed again, runs, beeps and prints, with no key
  touched. The earlier typed-program recording replays too (504 of 504). A copy with
  one port read removed from frame 100 stops there with a desync.
  - The player's port byte is swapped in inside the CPU, after its input register
    (`t80na.vhd`, marked NextTang), not on the bus as in the first simulation version:
    on the bus it lengthened the design's tightest path and no Nano build met timing
    (20 to 34 setup violations in six builds); after the register, five of six do.
  - A recording made by an emulator plays on the board: Fuse 1.6.0, a 48K Spectrum from
    power-on with the Next's 48K ROM, the ROM's start-up and then a two-line program
    typed and run (520 frames, Fuse's .szx snapshot). On the board: 520 of 520 frames,
    no desync, and the screen ends as in Fuse ("12", "34", "0 OK, 20:1"). The play tool
    reads Fuse's embedded .szx, and sets the interrupt mode, which the debugger cannot
    write, by single-stepping an IM instruction in RAM.
  - A game recording from the RZX Archive plays on the board: Jackal (48K, recorded in
    SPIN 0.5, a version 2 .z80 snapshot, interrupt mode 2): 22,453 of 22,453 frames,
    about seven and a half minutes of play, no desync. The play tool reads 48K .z80
    snapshots of any version. (Archive recordings hold game snapshots: local tests only,
    none are in this repository.)
  - Limits: 48K programs; about 230 bytes of recording per frame on average over the
    UART (the 1024-byte buffer takes single busier frames; Jackal's busiest has 284
    port reads).
  - Taking over: `rzx_play.py --until FRAME` ends the replay after that frame and
    leaves the machine running live (frame 300 of the BEEP recording: the keyboard
    works at once). divMMC automap stays off afterwards.
  - Turbo: `--speed 7` and `--speed 14` replay the 3.5 MHz recordings correctly at
    those CPU speeds. `--speed 28` desyncs at frame 72 every time; cause not known.
- 2026-11-15, exact-frame video on the Nano 20K, hardware-verified on one monitor: with
  `FRAME_EXACT` (on in the Nano top) the 48K and 128K/+3 frames are exactly one HDMI
  frame long, so the HDMI total never changes: 313 lines of 448 plus 400 at 50 Hz and
  261 plus 376 at 60 Hz for 48K, 308 of 456 plus 176 and 257 plus 112 for 128K/+3, the
  last line two pixels longer in 16 frames of 32 (50 Hz) or 11 of 32 (60 Hz). Pentagon
  timing is unchanged. 48K at 50 Hz is 70312.5 T-states a frame, not 69888. Before
  this the HDMI side followed the machine by whole front-porch lines, which a capture
  box accepted and a 60 Hz-only monitor did not (shaking, blanking); with it that
  monitor is steady at 60 Hz. Build results: four of four place-and-route runs meet
  timing without the replay option, none of six with `--rzx 3` (the replay byte choice
  in `t80na.vhd` is on a half-cycle path); that clash is open.
- 2026-11-16, 128K recordings on the Nano 20K, hardware-verified: `rzx_play.py --roms
  DIR` plays a 128K or +2 recording. The Next does not run those machines' ROMs, so the
  tool writes the two 16K ROM files (the user's own; none are in this repository) into
  the Next's alternate ROM pages through the debugger (2 MB addresses 0x18000 and
  0x1C000), switches them in for reads (NextREG 0x8C = 0x80), selects 128K timing,
  turns divMMC, Multiface and ports 1FFD and DFFD off, unlocks port 7FFD, and runs a
  few instructions in RAM that set the interrupt mode, the sound chip's sixteen
  registers and port 7FFD from the snapshot, none of which the debugger can write.
  Then it loads the eight RAM banks and the registers and plays as before. The tool
  reads 128K and +2 .z80 (versions 2 and 3) and .szx snapshots. A recording made in
  Fuse 1.6.0 from a 128K's power-on (its RAM test, the menu, 128 BASIC, typed lines; 905
  frames) plays in full, three runs of three, and to frame 400 at 14 MHz with the
  machine live afterwards. The machine stays that 128K until it is reset.
  - +2A and +3 recordings have four ROMs and there are two alternate pages, so for
    those the tool writes the four ROM files over the Next's own ROM pages (the first
    64K of the 2 MB memory), leaves the alternate ROM off and turns port 1FFD on; the
    Next's machine type already pages four ROMs from 1FFD and 7FFD. NextZXOS is then
    gone from memory until the board is restarted. A Fuse-made +3 recording from
    power-on (901 frames, into +3 BASIC) plays in full, one run. A snapshot in the
    +3's all-RAM paging mode is refused.
  - The set-up instructions end in HALT, for both 48K and 128K, because of a fault in
    NextTang's debugger support found here: writing the CPU state register while the
    CPU was held at the end of a multi-cycle instruction (a jump, say) cleared its
    instruction register, and the first bytes at the new PC were then skipped. Held in
    HALT that write is harmless. The first 128K runs went out of step at the first
    frame with a port read for this reason (the ROM's first instructions were
    skipped, so every later frame ended somewhere else). The 48K recordings were
    re-checked with the HALT set-up: BEEP 705 of 705, Fuse-made 520 of 520, Jackal
    22,453 of 22,453.
- 2026-11-16, core changes found through this work, hardware-verified on the Nano 20K
  (image `--rzx 3` with the exact frame, place 0 / route 2, `rzxV`):
  - The replay byte is back on `cpu_di` in `zxnext.vhd`, in the branch that chooses
    among port data, and `t80na.vhd` has no RZX change. (Where the byte goes in turned
    out not to decide timing: this is where the first version had it. The design's
    half-cycle paths are at the limit and results swing with placement.)
  - Timing constraints: the zxnDMA's data latch is no longer timed from the CPU's
    address and bus-grant registers (`nano20k_zxnext.sdc`); the DMA uses that byte
    only while it owns the bus. Builds with the replay option and the exact frame:
    5 of 6 placements met timing with this (`rzxU`), 1 of 3 after the last CPU change
    (`rzxV`, two more timed out). Still marginal.
  - Debugger, `t80n.vhd`: the state register write clears IR only when the CPU is
    halted (the fault above). Restarting from a `JR $` stop at a new PC ran the
    first instructions correctly 12 times of 12; before, never.
  - Debugger, `t80na.vhd`: the CPU's input register is kept from the moment the bus
    is given away until the CPU is in the first T-state of its next cycle
    (`Bus_Held`). The debugger's release shows on BUSAK at once but the CPU stays
    stopped a clock enable or two longer; stopped in T-state 3, the register loaded
    again from an undriven bus, and the stopped instruction's last byte, which
    reaches its register only during the next fetch, was lost. After a pause and
    resume right behind LD r,n, LD rr,nn, POP and the like, that register held FF.
    A program that checks its own registers failed at the first such pause; with the
    change it survives 1,000 pauses. Any program paused and resumed by the debugger
    was exposed to this, not only replays.
  - Player: the interrupt request no longer drops for one clock between the last
    fetch's M1 ending and the fetch count catching up. At 28 MHz the CPU samples the
    request on every clock and, after a four-T-state instruction, decided from that
    sample and missed the interrupt; this stopped 28 MHz replay at frame 72 of the
    BEEP recording. With it the BEEP, Fuse-made 48K and 128K recordings replay in
    full at 28 MHz (705 frames in 3.2 s).
  - Recordings on that image: BEEP at 3.5 and 28 MHz, Fuse-made 48K, take-over at
    frame 300 at 14 MHz, 128K at 3.5 and 28 MHz, +3: all in full, no desync.
  - The player waits for its stream (image `rzxW`, place 0 / route 2). Its `hold`
    output goes to the CPU's WAIT while a frame's header or the next port byte has
    not arrived, so the stream no longer has to keep up; a hold of about a second
    ends the replay with a desync, so a dead host cannot hang the machine. Before
    this the archive game stopped at frame 328 at 28 MHz (its busiest stretch needs
    about 24 KB/s of recording there and the UART carries 11.5), and a port read in
    the first instruction after a declined interrupt came before its byte. With it
    the archive game replays in full at 28 MHz: 22,453 frames in 91 s, against 448 s
    at 3.5 MHz. One limit is left by design: a frame of a single instruction
    straight after a declined interrupt (no real recording has one).
  - A third debugger fault, fixed: the debugger's view of the registers was one
    instruction behind. T80 writes an instruction's result into its register during
    the next opcode fetch (the last loaded byte, and ALU results), and the CPU is
    stopped before that fetch: single-stepping LD A,10 / INC A / INC A / INC A from
    A = 5A read 5A, 10, 11, 12, and a register the debugger wrote at a stop could be
    overwritten by the pending result at the resume. Now the pending result (register
    and flags) is applied in the first clock of a debugger hold (`Debug_Flush` in
    `t80n.vhd`) and not again afterwards, so the registers read at a stop are current
    and a snapshot taken at any stop is exact. `tests/test_debug_step_registers.py`
    steps 31 instructions on the CPU alone against a table (17 wrong before the fix),
    and `run_pi_debug.sh` checks four steps in the whole core.
    On the Nano 20K (rzxX-p0r2, 2026-11-16): 220 single steps of an 11-instruction
    loop all read current registers, a register written at a stop survived the next
    step, and 1,000 pause/resumes of a self-checking loop saw no wrong register.
    Three 8 s recordings captured in the middle of a running game (stops at
    arbitrary instructions, interrupts on and off; 400 frames each) play to their
    end in Fuse and on the board, and the six earlier recordings still replay (48K,
    128K, +3, the archive game at 3.5 and 28 MHz).
- 2026-11-16, `build_zxnext.sh --video-probe 1`: H on the debug UART returns a line
  about the HDMI picture path (`rtl/debug/nexttang_video_probe.v`: hdmi_frame's
  state, and counts of the core's frame locks, lines and lit lines in and out), for
  the loads that come up black with sync and sound present (about 1 in 50 of the
  `--rzx 3` image; none in 60 of the everyday image built from the same source).
  The black picture has so far shown on one build only (rzxS-p0r2: 4 in 139 loads)
  and on none of nine later images (about 400 loads), none of which is that build
  with the probe. Caught again on 2026-11-16 and read through the debugger: NextREGs
  and palettes are the same as on a good load, and Layer 2 switched on, a white
  palette, a display-timing change and a refresh-rate change all leave it black, so
  the fault is after the layer mix (the core's last output stage, or the line buffer
  and what follows). Cause unknown.
- 2026-11-16, rewind on the Nano 20K, hardware-verified (`--rzx 3` image rzxZ-p0r2;
  three placements met timing): `host/rzx_session.py` records a 48K program from a
  snapshot and, on a rewind, cuts the recording at the frame to go back to, puts the
  snapshot back, replays the cut recording at 28 MHz and carries on recording from
  there. What makes the join exact is in the board: a replay the host ends with
  FE 02 (instead of FE 01) hands over to the recorder on the clock playing ends,
  the recorder's first frame starting as many fetches long as the player had
  counted since the last frame it played (0 after an acknowledge, 1 or more after a
  declined interrupt), and the CPU is stopped there as at a breakpoint, until the
  host has put the CPU speed back and resumes.
  - In 48K BASIC: 1 typed, a rewind to before it, 2 typed: the screen shows only the
    2; the saved session (252 frames) plays to its end in Fuse 1.6.0 and on the
    board.
  - In the middle of a game (the archive recording played to frame 6,000 and taken
    over): a session with keys and three rewinds (back 2 s, 5 s and 1 s; replays of
    0.5, 0.8 and 1.4 s) saved as 505 frames, which play to their end in Fuse and on
    the board.
  - Cost: a rewind replays everything before the target at eight times real speed,
    so it takes an eighth of the session so far plus the snapshot write. Checkpoints
    on the board (the ring below) remove that; they are not built.
  - The frame at a join is short (the live frame interrupt arrives wherever it is
    when the replay ends); frame counts are therefore not exact time across a join.
  - The image with the USB keyboard as well (`--rzx 3 --companion 1`, rzxK-p1r2; two
    of three placements met timing) runs the same BASIC rewind session, and its
    recording plays to the end in Fuse. Its keys were sent from the PC; a real USB
    keyboard during a session has not been tried.
  - Not tried: sessions of minutes.
- 2026-11-16, first piece of the rewind ring: `rtl/debug/nexttang_dirty_blocks.v`
  keeps a bit per 256-byte block of the 2 MB, set by every write, and hands the dirty
  blocks to a checkpoint in a scan, clearing each as it is taken (unit tests: no
  write lost under random traffic with a stalling consumer). Nothing is copied yet.
  `build_zxnext.sh --dirty-probe 1` puts it on the CPU's memory writes with a count
  on the debug UART (`d`), to size the checkpoints:
  - on the board (image dirtyC-p1r2; one setup violation of 0.24 ns in the sprite
    line buffer, not in this logic): 48K BASIC at its prompt writes 3 blocks a
    second; a game standing still writes 9. (These two leave out bank 5, the
    screen and the 48K system variables: the core keeps it in block RAM and its
    writes never reach the memory port this probe watches; found on 2026-11-17.)
  - real play, counted by replaying board-made recordings of the game in a software
    Z80 on the PC: 41 blocks in a typical second (10 KB), 63 at most, and 61 to 68
    over 5 seconds, in three recordings of 8 to 10 s. One game only; a game that
    scrolls the whole screen will write more (the screen alone is 27 blocks).
  So a checkpoint every second copies tens of blocks, not thousands. The plan this
  points to for the Nano's 8 MB: 2 MB live, a 2 MB copy as of the last checkpoint,
  and 4 MB of undo records (for each dirty block, its content at the checkpoint
  before), so that going back is the copy plus the undo records in reverse.
- 2026-11-16, second piece of the rewind ring: `rtl/debug/nexttang_rewind_store.v`
  is the store described under piece 4 (the copy as of the last checkpoint, undo
  records in a ring, a table of the checkpoints held): prime, checkpoint, and rewind
  by a number of checkpoints, through one byte-wide memory port. Simulation only: with
  the tracker and a memory model, after random machine writes, checkpoints and
  rewinds the live memory is always what it was at the checkpoint gone back to,
  with a roomy ring, with one of seven records (old checkpoints dropped, and a
  checkpoint too big for the ring given up cleanly) and with a table of two; the
  test fails when the store is broken on purpose. Not on a board: it still needs
  the rest of the SDRAM on a port, banks 5 and 7, the CPU registers and commands
  from the host.
- 2026-11-16, towards the board: the SDRAM service's port C takes two more address
  bits and so reaches the whole 8 MB of the Nano's die (the core's port C has them
  tied to zero). Its simulation runs port C in all four quarters; on the board
  (wideC-p1r2, 0 setup and 0 hold) the 48K, 128K and archive recordings replay and
  300 pause/resumes are clean. Nothing uses the upper 6 MB yet.
- 2026-11-16, black picture: four more placements of the probe image (hunt-p1r0,
  p1r1, p2r0, p2r1) 0 in 240 loads, and seven earlier probe images 0 in 210 more.
  About 700 loads of eleven probe images without one; still only rzxS-p0r2.
- 2026-11-17, **the rewind ring on the Nano 20K**, working in a test image
  (`build_zxnext.sh --rzx 3 --rewind-ring 1`, `host/rzx_session.py --ring`).
  `rtl/debug/nexttang_ring_control.v` holds the tracker and the store and takes
  p (prime), g (checkpoint), r hh (rewind by that many checkpoints) and i (report)
  from the debug UART. It needs no change in the core: it shares memory port C with
  the debug slave for main memory, the copy (2 MiB at 0x200000), the undo ring
  (2 MiB at 0x400000) and each checkpoint's notes (at 0x600000: the 27 register
  bytes and the recorder's frame, fetch and port-read counts), and it shares the
  board's SPI master to give the debug slave its own commands: pause and resume,
  register reads and writes, and block RAM writes for bank 5 and half of bank 7.
  The host takes a checkpoint every few seconds; a rewind goes back to the last
  checkpoint before the moment wanted, replays from there (the first frame
  shortened by the counts in the notes) and hands over to the recorder as before.
  - In a game (the archive recording taken over at frame 6,000; image
    ringG-p0r2): a 150 s session with keys, a checkpoint every 5 s and eight
    rewinds (back 3, 18, 1, 30, 70, 200, 4 and 12 s; two of them to the very
    start) saved as 2,177 frames, which play to their end in Fuse 1.6.0 and on
    the board. Each rewind took 0.8 to 2.5 s, whatever the session's length.
    After a rewind to the start, the registers and all 48K of RAM read back equal
    to the session's snapshot.
  - A checkpoint stops the game for about a frame: the longest silence in the
    recorder's stream after each of 13 checkpoints was 20 to 39 ms (59 ms for
    the first after a 28 MHz replay), against 20 ms between frames otherwise.
    The prime at the start takes 2.4 s.
  - **Timing.** The ring takes the image from 90 % to 96 to 98 % of the device's
    logic, and whether a run meets timing is close to chance: of 20 runs of the
    logic as first finished none did (the best, ringG-p0r2, had 5 setup
    violations, worst -0.31 ns, and gave the results above). With the store
    slimmed (one ring pointer, records counted instead of bytes), 2 of 9 runs
    meet timing: ringH-p1r2 and p2r2, 0 setup and 0 hold violations. On
    **ringH-p1r2**: the six-region rewind check passes; the 48K BEEP recording at
    28 MHz and the Fuse-made 128K recording replay; the same 150 s game session
    (eight rewinds, 0.8 to 2.5 s each) saved 2,164 frames that play to their end
    in Fuse and on the board; the silence after each of seven checkpoints was 20
    to 40 ms.
  - A longer session (ringG-p0r2): 400 s with keys throughout, 80 checkpoints
    (the ring's table holds 64) and four rewinds, saved 719 frames that play to
    the end in Fuse and on the board. The rewind to the very start, back over
    some thirty checkpoints, took 17.8 s: undoing a checkpoint writes bank 5's
    blocks back through the debug slave a byte a command, for every checkpoint
    undone. Rewinds of a few checkpoints took 1.5 to 4 s.
  - Faults found and fixed on the way, each first seen on the board:
    - the ring drove port C's read/write line the wrong way round (0 is a read);
      the simulation's port model had the same mistake and passed;
    - bank 5's writes never reach port A, so its blocks were never marked: they
      are now taken from the bus (a memory write to a slot whose MMU page is 0A,
      0B or 0E);
    - an interrupt that passes while the CPU is stopped for a checkpoint was
      given a frame end by the recorder, though the CPU never saw it; a replay
      then took an interrupt the run had not. The board now holds the
      recorder's INT high while the CPU is stopped and tells it to forget a
      pulse cut by the stop (`int_cut`). Frames that lose their interrupt that
      way are longer than a video frame; Fuse warns ("RZX frame is longer than
      79000 tstates") and plays them;
    - a replay of one frame could end before the host's end code arrived and
      run on: both host tools now end the stream with three bytes of a header
      and then the end code (`rtl/debug/nexttang_rzx_play_link.v`);
    - reading bank 5 a byte a command through the slave made each checkpoint
      stop the game for a third of a second; the SDRAM at bank 5's and 7's
      addresses now holds a mirror, written as the machine writes, and a
      checkpoint reads that (the slave is still used for a stale mirror and for
      writing the banks back in a rewind).
  - Limits: 48K programs; the interrupt mode is not restored (the tool falls back
    to the long way if it differs); an interrupt is lost whenever a checkpoint's
    stop covers it; a rewind over many checkpoints is slow (above); the device is
    nearly full, so any change to this image needs several runs to find one that
    meets timing.
- Next: the ring image with the USB keyboard, bank 5 written back once per rewind
  instead of once per checkpoint undone, the main branch, and the 138K with the
  recording on the SD card.

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
