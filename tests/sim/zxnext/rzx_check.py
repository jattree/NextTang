#!/usr/bin/env python3
"""Check the RZX input recorder against the real core.

Input: the dump tb_zxnext_trace.vhd writes with RZX_DUMP (the CPU's M1, IORQ
and RD, its input register and its R register, one line per change). Two
checks:

1. The RZX frames worked out here from the bus (one fetch per M1 cycle that is
   not an interrupt acknowledge; each I/O read's byte from the input register
   once the cycle ends) agree with the CPU's R register: between two interrupt
   acknowledges R advances by the frame's fetches plus one for the
   acknowledge, modulo 128.
2. rtl/debug/nexttang_rzx_logger.v, simulated with the same signals clock by
   clock, produces exactly those frames.

With --write-stream, the frames are also written as the player's input (one
hex byte per line: fetch count, IN count, IN bytes, as in an RZX file). With
--expect STREAM, the frames must be those of STREAM: the check for a replay
(the dump of a run played from STREAM), and with --expect-differ the check
that a run's inputs really changed (the frames must not match).

Usage: rzx_check.py DUMP [--keep DIR] [--write-stream FILE]
                         [--expect STREAM [--expect-differ]]
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
from tools.rzx import Frame, frames_from_logger  # noqa: E402

LOGGER = REPO_ROOT / "rtl/debug/nexttang_rzx_logger.v"


def read_dump(path: Path) -> list[tuple[int, int, int, int, int, int]]:
    events = []
    for line in path.read_text(encoding="ascii").splitlines():
        cycle, m1, iorq, rd, di, r = line.split()
        if not all(c in "01" for c in m1 + iorq + rd):
            continue  # strobes undefined before reset
        # The input and R registers are undefined until first written (the
        # first fetch happens before either is): keep the strobes, which are
        # what count, and read an undefined register as 0xFF / 0.
        try:
            di_value = int(di, 16)
        except ValueError:
            di_value = 0xFF
        try:
            r_value = int(r, 16)
        except ValueError:
            r_value = 0
        events.append((int(cycle), int(m1), int(iorq), int(rd), di_value, r_value))
    return events


def reference(events) -> tuple[list[Frame], list[str]]:
    """Frames from the bus, and any disagreement with the R register."""
    frames: list[Frame] = []
    problems: list[str] = []
    fetches = 0
    inputs = bytearray()
    in_m1 = ack = in_io = False
    io_end_cycle = None
    previous_di = 0xFF
    r_at_m1 = 0
    last_ack_r = None
    for cycle, m1, iorq, rd, di, r in events:
        # The read's byte: the input register one cycle after the read ends.
        if io_end_cycle is not None and cycle > io_end_cycle:
            inputs.append(di if cycle == io_end_cycle + 1 else previous_di)
            io_end_cycle = None
        previous_di = di
        if not in_m1 and m1 == 0:
            in_m1, ack, r_at_m1 = True, False, r
        if in_m1 and iorq == 0:
            ack = True
        if in_m1 and m1 == 1:
            in_m1 = False
            if ack:
                if last_ack_r is not None and (r_at_m1 - last_ack_r) % 128 != (fetches + 1) % 128:
                    problems.append(f"cycle {cycle}: frame {len(frames)} has {fetches} fetches, "
                                    f"R advanced {(r_at_m1 - last_ack_r) % 128}")
                last_ack_r = r_at_m1
                frames.append(Frame(fetches, bytes(inputs)))
                fetches = 0
                inputs.clear()
            else:
                fetches += 1
        io = m1 == 1 and iorq == 0 and rd == 0
        if in_io and not io:
            io_end_cycle = cycle
        in_io = io
    return frames, problems


BENCH = """
module testbench;
    reg clock = 0;
    always #5 clock = ~clock;
    reg reset = 1, start = 0;
    reg m1_n = 1, iorq_n = 1, rd_n = 1;
    reg [7:0] data = 8'hff;
    wire [8:0] word;
    wire valid, recording, saturated, overflow;
    wire [15:0] frames;
    integer f, out, cycle, now, m1, iorq, rd, di, r, n;

    nexttang_rzx_logger dut (
        .clock(clock), .reset(reset), .start(start), .stop(1'b0),
        .recording(recording), .m1_n(m1_n), .iorq_n(iorq_n), .rd_n(rd_n),
        .data(data), .word(word), .word_valid(valid), .word_ready(1'b1),
        .frames(frames), .saturated(saturated), .overflow(overflow));

    always @(posedge clock)
        if (valid) $fdisplay(out, "%03x", word);

    initial begin
        f = $fopen("events.txt", "r");
        out = $fopen("words.txt", "w");
        @(posedge clock); reset <= 0;
        @(posedge clock); start <= 1;
        @(posedge clock); start <= 0;
        now = 0;
        while ($fscanf(f, "%d %d %d %d %h %h\\n", cycle, m1, iorq, rd, di, r) == 6) begin
            while (now < cycle) begin @(posedge clock); now = now + 1; end
            m1_n <= m1; iorq_n <= iorq; rd_n <= rd; data <= di;
        end
        repeat (8) @(posedge clock);
        $display("LOGGER frames=%0d saturated=%0d overflow=%0d", frames, saturated, overflow);
        $fclose(out);
        $finish;
    end
endmodule
"""


def run_logger(events, work: Path) -> tuple[list[int], str]:
    # Values change just after a clock edge, as the core's registers do, so
    # each event applies from the edge of its cycle onwards.
    with open(work / "events.txt", "w", encoding="ascii") as handle:
        for cycle, m1, iorq, rd, di, r in events:
            handle.write(f"{cycle} {m1} {iorq} {rd} {di:02x} {r:02x}\n")
    (work / "testbench.v").write_text(BENCH, encoding="ascii")
    subprocess.run(["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o", "tb.vvp",
                    str(LOGGER), "testbench.v"], cwd=work, check=True)
    result = subprocess.run(["vvp", "tb.vvp"], cwd=work, check=True, capture_output=True, text=True)
    status = next(line for line in result.stdout.splitlines() if line.startswith("LOGGER"))
    words = [int(line, 16) for line in (work / "words.txt").read_text().split()]
    return words, status


def write_stream(frames: list[Frame], path: Path) -> None:
    with open(path, "w", encoding="ascii") as handle:
        for frame in frames:
            for byte in (frame.fetches & 0xFF, frame.fetches >> 8,
                         len(frame.inputs) & 0xFF, len(frame.inputs) >> 8, *frame.inputs):
                handle.write(f"{byte:02x}\n")


def read_stream(path: Path) -> list[Frame]:
    data = bytes(int(line, 16) for line in path.read_text(encoding="ascii").split())
    frames, position = [], 0
    while position < len(data):
        fetches = data[position] | data[position + 1] << 8
        count = data[position + 2] | data[position + 3] << 8
        frames.append(Frame(fetches, data[position + 4:position + 4 + count]))
        position += 4 + count
    return frames


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("dump", type=Path)
    parser.add_argument("--keep", type=Path, help="keep the logger simulation's files here")
    parser.add_argument("--write-stream", type=Path, help="write the frames as the player's input")
    parser.add_argument("--expect", type=Path, help="the frames must be this player input's")
    parser.add_argument("--expect-differ", action="store_true", help="with --expect: they must not be")
    args = parser.parse_args()
    events = read_dump(args.dump)
    expected, problems = reference(events)
    ins = sum(len(frame.inputs) for frame in expected)
    print(f"{len(events)} bus events, {len(expected)} frames, "
          f"{sum(frame.fetches for frame in expected)} fetches, {ins} IN reads")
    for frame_no, frame in enumerate(expected):
        print(f"  frame {frame_no}: {frame.fetches} fetches, {len(frame.inputs)} INs")
    for problem in problems:
        print("R MISMATCH", problem)
    if args.keep:
        args.keep.mkdir(parents=True, exist_ok=True)
        work = args.keep
        words, status = run_logger(events, work)
    else:
        with tempfile.TemporaryDirectory() as directory:
            words, status = run_logger(events, Path(directory))
    print(status)
    got = frames_from_logger(words)
    ok = not problems and got == expected and "saturated=0 overflow=0" in status
    if got != expected:
        for index, (a, b) in enumerate(zip(got, expected)):
            if a != b:
                print(f"LOGGER MISMATCH frame {index}: logger {a.fetches} fetches "
                      f"{a.inputs.hex()} reference {b.fetches} fetches {b.inputs.hex()}")
                break
        else:
            print(f"LOGGER MISMATCH: logger {len(got)} frames, reference {len(expected)}")
    if args.write_stream:
        write_stream(expected, args.write_stream)
        print(f"wrote {args.write_stream}: {len(expected)} frames")
    if args.expect:
        wanted = read_stream(args.expect)
        same = expected == wanted
        print(f"against {args.expect}: {len(wanted)} frames there, {len(expected)} here, "
              f"{'identical' if same else 'different'}")
        if not same:
            for index, (a, b) in enumerate(zip(expected, wanted)):
                if a != b:
                    print(f"  first difference, frame {index}: {a.fetches} fetches {a.inputs.hex()} "
                          f"against {b.fetches} fetches {b.inputs.hex()}")
                    break
        if same == args.expect_differ:
            ok = False
    if len(expected) < 3:
        print("too few frames for an R check")
        ok = False
    print("RZX_CHECK", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    if not shutil.which("iverilog"):
        sys.exit("rzx_check: iverilog is not installed")
    sys.exit(main())
