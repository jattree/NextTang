#!/usr/bin/env python3
"""Play a 48K Spectrum program on a NextTang board with rewind.

Needs an image with the RZX recorder and player (Nano 20K: build_zxnext.sh
--rzx 3) and the debugger on the debug UART (--pi-pins 0).

The tool takes a snapshot of the running program, as host/rzx_capture.py does,
and records every input from then on. A rewind goes back in time:

1. the recording so far is cut at the frame to go back to;
2. the snapshot is put back and the cut recording is replayed at 28 MHz
   (eight times real speed), as host/rzx_play.py does;
3. the replay ends with FE 02, so the board hands the machine to the recorder
   at that frame and stops the CPU there: the recording carries on from the
   frame the replay reached, without a seam;
4. the CPU speed is put back and, on Enter, the program goes on from the
   earlier moment, with the keys free again.

So the cost of a rewind grows with the session: an eighth of the time played
so far, plus about ten seconds for the snapshot. (The rewind ring planned for
the Console 138K keeps checkpoints on the board instead.)

While it runs, type on this terminal:

    Enter        rewind 10 seconds (or --step)
    N Enter      rewind N seconds
    q Enter      stop; the whole session is written as one RZX file

and after a rewind, Enter to go on. The file holds the session as it finally
went: what was rewound over is not in it.

--script runs a timeline instead of the terminal, for tests:
SECONDS:ACTION,... with ACTION a key mask (K and 10 hex digits, as the board's
K command), R and the seconds to rewind, or Q. Seconds count from the start
and stand still during a rewind; it goes on at once after each rewind.

Only 48K programs so far, as rzx_capture.py; divMMC automapping is turned off
for the session and put back at the end.
"""

from __future__ import annotations

import argparse
import os
import select
import sys
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "host"))
sys.path.insert(0, str(ROOT / "host/debug"))
from nexttang_debug.protocol import CMD_CPU_RESUME, CMD_NEXTREG_W, CPU_STATE_WRITE, PiDebug, Z80Memory  # noqa: E402
from nexttang_debug.uart import UartLink  # noqa: E402
from tools.rzx import Creator, Frame, Recording, Rzx, Snapshot, frames_from_uart, write  # noqa: E402
from rzx_capture import DEFAULT_PORT, PAGES_48K, z80_v1  # noqa: E402
from rzx_play import BUFFER, KEEP_FREE, PREFILL_MAX, escaped, frame_bytes, run_setup  # noqa: E402

FRAMES_PER_SECOND = 50
REGISTERS = ("AF", "BC", "DE", "HL", "AF'", "BC'", "DE'", "HL'", "IX", "IY", "SP", "PC", "I", "R")


class SessionError(RuntimeError):
    pass


class Session:
    def __init__(self, port: str, say=print) -> None:
        self.port = port
        self.say = say
        self.link: UartLink | None = None
        self.regs: dict[str, int] = {}
        self.ram = b""
        self.speed = 0                  # NextREG 0x07 bits 1:0 while live
        self.kept: list[Frame] = []     # frames from before the last rewind
        self.captured = bytearray()     # the recorder's bytes since then
        self.rewinds = 0

    # ---------------------------------------------------------------- start
    def start(self) -> None:
        """Snapshot the paused machine, arm the recorder and resume."""
        self.link = UartLink(self.port, 115200, timeout=2.0)
        debug = PiDebug(self.link)
        self.nr0a = debug.nextreg(0x0A)
        if self.nr0a & 0x10:
            debug.set_nextreg(0x0A, self.nr0a & ~0x10)
            self.say(f"divMMC automap off (NextREG 0x0A {self.nr0a:02X} -> {self.nr0a & ~0x10:02X}) for the session")
            time.sleep(1.0)
        debug.pause()
        memory = Z80Memory(debug)
        pages = memory.pages()
        if pages != PAGES_48K:
            debug.resume()
            raise SessionError(f"not the 48K memory map: MMU {' '.join(f'{p:02X}' for p in pages)}")
        self.speed = debug.nextreg(0x07) & 3
        regs = debug.registers()
        if regs["HALT"]:
            debug.set_register("PC", (regs["PC"] - 1) & 0xFFFF)   # also leaves HALT
            regs = debug.registers()
        self.regs = regs
        self.ram = memory.read(0x4000, 0xC000)
        self.say(f"snapshot: PC {regs['PC']:04X} SP {regs['SP']:04X} IM {regs['IM']} IFF1 {regs['IFF1']}")
        self._raw(b"Z")
        time.sleep(0.05)
        self._raw(b"X\x04" + bytes([CMD_CPU_RESUME, 0, 0, 0]))
        self.captured = bytearray()

    def _raw(self, data: bytes) -> None:
        assert self.link is not None
        self.link.write(data)
        termios.tcdrain(self.link.fd)

    def pump(self, wait: float = 0.05) -> None:
        """Take what the recorder has sent."""
        assert self.link is not None
        ready, _, _ = select.select([self.link.fd], [], [], wait)
        if ready:
            self.captured += os.read(self.link.fd, 65536)

    def key(self, mask: str) -> None:
        self._raw(b"K" + mask.encode())

    def frames_so_far(self) -> int:
        try:
            return len(self.kept) + len(frames_from_uart(bytes(self.captured)).frames)
        except Exception:
            return len(self.kept)

    # ----------------------------------------------------------------- stop
    def _stop_recorder(self) -> list[Frame]:
        """Stop the recorder and return the session's frames so far."""
        self._raw(b"z")
        deadline = time.monotonic() + 30
        while True:
            self.pump()
            if b"\xfd" in self.captured and b"RZX!" in self.captured:
                recording = frames_from_uart(bytes(self.captured))
                if recording.complete:
                    break
            if time.monotonic() > deadline:
                raise SessionError("no end marker within 30 s of stopping the recorder")
        problems = []
        if recording.flags & 1:
            problems.append("a frame's fetch count saturated")
        if recording.flags & 2:
            problems.append("the recorder's FIFO overflowed: bytes were lost")
        if recording.frame_count != len(recording.frames):
            problems.append(f"board counted {recording.frame_count} frames, {len(recording.frames)} arrived")
        if problems:
            raise SessionError("; ".join(problems))
        return self.kept + recording.frames

    def finish(self, output: Path) -> int:
        frames = self._stop_recorder()
        assert self.link is not None
        self._raw(b"K0000000000")
        time.sleep(0.3)
        termios.tcflush(self.link.fd, termios.TCIFLUSH)
        self.link.pending.clear()
        if self.nr0a & 0x10:
            PiDebug(self.link).set_nextreg(0x0A, self.nr0a)
            self.say(f"NextREG 0x0A restored to {self.nr0a:02X}")
        self.link.close()
        snapshot = z80_v1(self.regs, self.ram)
        write(output, Rzx([Creator("NextTang", 0, 1), Snapshot("Z80", snapshot), Recording(0, frames)]))
        ins = sum(len(f.inputs) for f in frames)
        self.say(f"{output}: {len(frames)} frames ({len(frames) / FRAMES_PER_SECOND:.1f} s), {ins} IN values, "
                 f"{self.rewinds} rewind{'s' if self.rewinds != 1 else ''}")
        return len(frames)

    # --------------------------------------------------------------- rewind
    def rewind(self, seconds: float) -> int:
        """Go back `seconds`; the CPU is left stopped at that frame with the
        recorder running. Returns the frame gone back to."""
        frames = self._stop_recorder()
        target = max(1, len(frames) - round(seconds * FRAMES_PER_SECOND))
        frames = frames[:target]
        assert self.link is not None
        link = self.link
        fd = link.fd
        time.sleep(0.2)
        termios.tcflush(fd, termios.TCIFLUSH)
        link.pending.clear()
        debug = PiDebug(link)
        debug.pause()
        memory = Z80Memory(debug)
        regs = self.regs
        run_setup(debug, memory, 0xC000, regs["IM"], [])
        memory.write(0x4000, self.ram)
        for name in REGISTERS:
            debug.set_register(name, regs[name])
        debug.set_cpu_register(CPU_STATE_WRITE, regs["IFF2"] << 1 | regs["IFF1"])
        check = debug.registers()
        wrong = [n for n in ("AF", "BC", "DE", "HL", "IX", "IY", "SP", "PC", "I", "IM", "IFF1", "IFF2", "HALT")
                 if check[n] != (regs[n] if n != "HALT" else 0)]
        if wrong or memory.read(0x4000, 0x100) != self.ram[:0x100] or memory.read(0xFF00, 0x100) != self.ram[-0x100:]:
            debug.resume()
            raise SessionError(f"the snapshot did not go back in (registers that differ: {wrong})")
        debug.set_nextreg(0x07, 3)      # 28 MHz for the replay

        sizes = [4 + len(f.inputs) for f in frames]
        sent = 0
        prefill = b""
        while sent < len(frames) and len(prefill) + sizes[sent] <= PREFILL_MAX:
            prefill += frame_bytes(frames[sent])
            sent += 1
        sent_bytes = len(prefill)
        self._raw(b"P" + bytes([len(prefill)]) + prefill)
        time.sleep(0.05)
        self._raw(b"X\x01" + bytes([CMD_CPU_RESUME]))
        time.sleep(0.002)
        termios.tcflush(fd, termios.TCIFLUSH)

        started = time.monotonic()
        done = done_bytes = 0
        ended = False
        tail = bytearray()
        result = None
        after = bytearray()             # the recorder's first bytes, right behind the result
        while result is None:
            out = b""
            while sent < len(frames) and sent_bytes - done_bytes + sizes[sent] <= BUFFER - KEEP_FREE:
                out += escaped(frame_bytes(frames[sent]))
                sent_bytes += sizes[sent]
                sent += 1
            if sent == len(frames) and not ended:
                # A header that is not played, then the end that hands over
                # to the recorder and stops the CPU.
                out += b"\xff\xff\x00\x00" + b"\xfe\x02"
                ended = True
            if out:
                link.write(out)
            ready, _, _ = select.select([fd], [], [], 0.02)
            if ready:
                data = os.read(fd, 4096)
                for index, value in enumerate(data):
                    if tail or value & 0xF8 == 0x80:
                        tail.append(value)
                        if len(tail) == 3:
                            result = (tail[0] & 7, tail[1] | tail[2] << 8)
                            after += data[index + 1:]
                            break
                    elif value & 0x40:
                        for _ in range((value - done) & 0x3F):
                            if done < len(frames):
                                done_bytes += sizes[done]
                            done += 1
            if time.monotonic() - started > len(frames) / 45 + 10:
                raise SessionError("no result from the board during the replay")
        flags, played = result
        if flags != 4 or played != len(frames):
            # The machine is live wherever the replay left it, unrecorded.
            self._raw(b"X\x04" + bytes([CMD_NEXTREG_W, 0x07, self.speed, 0]))
            raise SessionError(f"the replay went wrong after {played} of {len(frames)} frames "
                               f"(desync {flags & 1}, buffer overflow {flags >> 1 & 1})")
        # The board has started the recorder and is stopping the CPU. The
        # UART's transmit side is the recorder's from here, so the debugger's
        # replies do not come back: the speed goes in unanswered.
        time.sleep(0.05)
        self._raw(b"X\x04" + bytes([CMD_NEXTREG_W, 0x07, self.speed, 0]))
        time.sleep(0.02)
        self.kept = frames
        self.captured = after
        self.rewinds += 1
        self.say(f"back at frame {target} ({target / FRAMES_PER_SECOND:.1f} s) after "
                 f"{time.monotonic() - started:.1f} s of replay; the program is stopped there")
        return target

    def go_on(self) -> None:
        self._raw(b"X\x04" + bytes([CMD_CPU_RESUME, 0, 0, 0]))


def parse_script(text: str) -> list[tuple[float, str]]:
    plan = []
    for item in filter(None, text.split(",")):
        at, action = item.split(":")
        action = action.strip()
        if not (action[:1] == "K" and len(action) == 11 or action[:1] == "R" and len(action) > 1 or action == "Q"):
            raise ValueError(f"script action not understood: {action}")
        plan.append((float(at), action))
    return sorted(plan)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("output", type=Path, help="the .rzx to write at the end")
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--step", type=float, default=10.0, help="seconds a plain Enter rewinds (default 10)")
    parser.add_argument("--script", default=None, help="a timeline instead of the terminal (see above)")
    args = parser.parse_args(argv)
    try:
        plan = parse_script(args.script) if args.script is not None else None
    except ValueError as error:
        parser.error(str(error))

    session = Session(args.port)
    try:
        session.start()
        if plan is None:
            print(f"recording. Enter: rewind {args.step:g} s; a number and Enter: rewind that many seconds; q Enter: stop")
        clock = 0.0                      # session seconds, standing still during rewinds
        last = time.monotonic()
        while True:
            session.pump(0.02)
            now = time.monotonic()
            clock += now - last
            last = now
            command = None
            if plan is not None:
                if plan and plan[0][0] <= clock:
                    command = plan.pop(0)[1]
            elif select.select([sys.stdin], [], [], 0)[0]:
                line = sys.stdin.readline()
                command = "Q" if not line or line.strip().lower() == "q" else "R" + (line.strip() or str(args.step))
            if command is None:
                continue
            if command[0] == "K":
                session.key(command[1:].lower())
            elif command == "Q":
                break
            else:
                try:
                    seconds = float(command[1:])
                except ValueError:
                    print("a number of seconds, Enter, or q")
                    continue
                session.rewind(seconds)
                if plan is None:
                    input("Enter to go on from here: ")
                session.go_on()
                last = time.monotonic()
        session.finish(args.output)
    except (SessionError, RuntimeError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
