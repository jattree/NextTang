"""Simulation tests for the RZX input recorder (rtl/debug/nexttang_rzx_logger.v)."""

from __future__ import annotations

import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/debug/nexttang_rzx_logger.v"

BENCH_HEAD = """
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    always #5 clock = ~clock;
    reg reset = 1, start = 0, stop = 0;
    reg m1_n = 1, iorq_n = 1, rd_n = 1, int_n = 1;
    reg [7:0] data = 8'hff;
    reg ready = 1;
    reg random_ready = 0;
    wire [8:0] word;
    wire valid, recording, saturated, overflow;
    wire [15:0] frames;
    integer got = 0;
    reg [8:0] seen [0:65535];

    nexttang_rzx_logger #(.FIFO_BITS(FIFO_BITS)) dut (
        .clock(clock), .reset(reset), .start(start), .stop(stop),
        .recording(recording), .m1_n(m1_n), .iorq_n(iorq_n), .rd_n(rd_n),
        .data(data), .int_n(int_n), .word(word), .word_valid(valid), .word_ready(ready),
        .frames(frames), .saturated(saturated), .overflow(overflow));

    always @(posedge clock) begin
        if (valid && ready) begin
            seen[got] <= word;
            got <= got + 1;
        end
        if (random_ready)
            ready <= $random & 1;
    end

    // One T-state is CPU_CLOCKS core clocks.
    task tstates(input integer n); begin repeat (n * CPU_CLOCKS) @(posedge clock); end endtask
    // Opcode fetch: M1 low for T1-T2, refresh T3-T4 (see below).
    // I/O read: IORQ and RD low from T2 to T3 (with the automatic wait state).
    // `data` models the CPU's input register: it holds the previous cycle's
    // byte until the latch in T3, then this read's byte until the next T3.
    task in_read(input [7:0] value); begin
        tstates(1); iorq_n <= 0; rd_n <= 0; tstates(2);
        data <= value; tstates(1); iorq_n <= 1; rd_n <= 1; tstates(1);
    end endtask
    // The next cycle's T3 overwrites the register (an opcode fetch's refresh
    // T3 latches whatever is on the bus).
    task fetch; begin m1_n <= 0; tstates(2); m1_n <= 1; data <= $random; tstates(2); end endtask
    // I/O write: must not be recorded.
    task out_write; begin
        tstates(1); iorq_n <= 0; tstates(3); iorq_n <= 1; tstates(1);
    end endtask
    // Interrupt acknowledge: INT low, then M1 low, IORQ low two T-states
    // later; INT rises after the acknowledge, as the ULA's 32 T-state pulse.
    task ack; begin
        int_n <= 0; tstates(1);
        m1_n <= 0; tstates(2); iorq_n <= 0; tstates(2); m1_n <= 1; iorq_n <= 1; tstates(3);
        int_n <= 1;
    end endtask
    // An interrupt the CPU ignores (interrupts disabled): INT low for a while
    // with fetches going on, then high again.
    task missed_int(input integer fetches_during); integer k; begin
        int_n <= 0; tstates(1);
        for (k = 0; k < fetches_during; k = k + 1) fetch;
        int_n <= 1; tstates(1);
    end endtask
    task many_fetches(input integer n); integer k; begin for (k = 0; k < n; k = k + 1) fetch; end endtask

    initial begin
        repeat (4) @(posedge clock);
        reset <= 0;
        @(posedge clock);
"""

BENCH_TAIL = """
        repeat (64) @(posedge clock);
        $display("RESULT got=%0d frames=%0d saturated=%0d overflow=%0d recording=%0d",
                 got, frames, saturated, overflow, recording);
        for (i = 0; i < got; i = i + 1) $display("W %03x", seen[i]);
        $finish;
    end
    integer i;
endmodule
"""


def run_bench(body: str, cpu_clocks: int = 8, fifo_bits: int = 5) -> tuple[dict, list[int]]:
    bench = (BENCH_HEAD.replace("module testbench;",
                                f"module testbench;\n    localparam CPU_CLOCKS = {cpu_clocks};"
                                f"\n    localparam FIFO_BITS = {fifo_bits};")
             + body + BENCH_TAIL)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "testbench.v").write_text(bench, encoding="ascii")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
             str(root / "tb.vvp"), str(RTL), str(root / "testbench.v")],
            cwd=REPO_ROOT, capture_output=True, text=True, check=False)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(["vvp", str(root / "tb.vvp")], cwd=REPO_ROOT,
                                capture_output=True, text=True, check=False, timeout=600)
    lines = result.stdout.splitlines()
    summary = next(line for line in lines if line.startswith("RESULT"))
    fields = dict(part.split("=") for part in summary.split()[1:])
    words = [int(line.split()[1], 16) for line in lines if line.startswith("W ")]
    return {k: int(v) for k, v in fields.items()}, words


def frame_words_split(words: list[int]) -> list[tuple[int, list[int]]]:
    frames, ins, low = [], [], None
    for w in words:
        if w & 0x100:
            if low is None:
                low = w & 0xFF
            else:
                frames.append(((w & 0xFF) << 8 | low, ins)); ins, low = [], None
        else:
            ins.append(w)
    return frames


def frame_words(in_bytes: list[int], fetches: int) -> list[int]:
    return [b for b in in_bytes] + [0x100 | (fetches & 0xFF), 0x100 | (fetches >> 8)]


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class RzxLoggerTest(unittest.TestCase):
    def test_random_frames_with_backpressure(self) -> None:
        rng = random.Random(1982)
        body = ["        start <= 1; @(posedge clock); start <= 0;",
                "        random_ready <= 1;"]
        expected: list[int] = []
        # Activity before the first interrupt is a frame too (RZX's first frame
        # runs from the snapshot to the first interrupt).
        for _ in range(12):
            fetches = 0
            ins: list[int] = []
            for _ in range(rng.randrange(0, 60)):
                kind = rng.random()
                if kind < 0.7:
                    body.append("        fetch;")
                    fetches += 1
                elif kind < 0.9:
                    value = rng.randrange(256)
                    body.append(f"        fetch; in_read(8'h{value:02x});")
                    fetches += 1
                    ins.append(value)
                else:
                    body.append("        fetch; out_write;")
                    fetches += 1
            body.append("        ack;")
            expected += frame_words(ins, fetches)
        # A partial frame at stop gets no frame end; its IN bytes are left as
        # trailing untagged words for the reader to drop.
        body.append("        fetch; in_read(8'h77); fetch;")
        expected.append(0x77)
        body.append("        stop <= 1; @(posedge clock); stop <= 0;")
        body.append("        fetch; ack;")
        body.append("        random_ready <= 0; ready <= 1;")
        status, words = run_bench("\n".join(body) + "\n")
        self.assertEqual(words, expected)
        self.assertEqual(status["frames"], 12)
        self.assertEqual(status["saturated"], 0)
        self.assertEqual(status["overflow"], 0)
        self.assertEqual(status["recording"], 0)

    def test_full_speed_cpu(self) -> None:
        # At 28 MHz the CPU clock enable is every core clock.
        body = """        start <= 1; @(posedge clock); start <= 0;
        fetch; in_read(8'h12); fetch; fetch; in_read(8'h34); ack;
        fetch; ack;
"""
        status, words = run_bench(body, cpu_clocks=1)
        self.assertEqual(words, frame_words([0x12, 0x34], 3) + frame_words([], 1))
        self.assertEqual(status["overflow"], 0)

    def test_nothing_recorded_before_start(self) -> None:
        body = """        fetch; in_read(8'haa); ack;
        start <= 1; @(posedge clock); start <= 0;
        fetch; fetch; ack;
"""
        _, words = run_bench(body)
        self.assertEqual(words, frame_words([], 2))

    def test_count_saturates(self) -> None:
        body = """        start <= 1; @(posedge clock); start <= 0;
        many_fetches(65540); ack;
"""
        status, words = run_bench(body, cpu_clocks=1)
        self.assertEqual(status["saturated"], 1)
        self.assertEqual(words, frame_words([], 0xFFFF))

    def test_missed_interrupt_ends_a_frame(self) -> None:
        # DI, frame interrupts come and go, EI, then one is taken.
        body = """        start <= 1; @(posedge clock); start <= 0;
        repeat (5) fetch; in_read(8'h21);
        missed_int(3);
        repeat (4) fetch; in_read(8'h43); fetch;
        missed_int(0);
        repeat (2) fetch;
        ack;
"""
        status, words = run_bench(body)
        # Fetches made while INT is low count before the frame end at its rise.
        self.assertEqual(words, frame_words([0x21], 8) + frame_words([0x43], 5) + frame_words([], 2))
        self.assertEqual(status["frames"], 3)

    def test_missed_interrupt_beside_an_in_read(self) -> None:
        # INT rising on every clock around the end of an IN read: the byte stays
        # in the frame before the boundary and nothing is lost.
        for offset in range(-6, 7):
            with self.subTest(offset=offset):
                body = f"""        start <= 1; @(posedge clock); start <= 0;
        fetch; int_n <= 0;
        fork
            in_read(8'h5c);
            begin repeat ({4 * 1 + 2 * 1 + 6 + offset}) @(posedge clock); int_n <= 1; end
        join
        fetch; fetch; ack;
"""
                status, words = run_bench(body, cpu_clocks=1)
                self.assertEqual(status["overflow"], 0)
                frames = frame_words_split(words)
                self.assertEqual(len(frames), 2, words)                  # the missed one, then the ack
                self.assertEqual(sum(f[0] for f in frames), 3)           # three fetches in all
                self.assertEqual([b for f in frames for b in f[1]], [0x5C])

    def test_overflow_when_consumer_stalls(self) -> None:
        body = """        start <= 1; @(posedge clock); start <= 0;
        ready <= 0;
        repeat (40) begin fetch; in_read(8'h01); end
        ack;
        ready <= 1;
"""
        status, words = run_bench(body, fifo_bits=4)
        self.assertEqual(status["overflow"], 1)
        self.assertEqual(len(words), 16)


if __name__ == "__main__":
    unittest.main()
