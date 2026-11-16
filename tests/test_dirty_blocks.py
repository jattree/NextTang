"""The rewind ring's dirty-block tracker (rtl/debug/nexttang_dirty_blocks.v)."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/debug/nexttang_dirty_blocks.v"

BENCH = """
`timescale 1ns/1ps
module testbench;
    localparam BLOCK_BITS = 5;
    localparam BLOCKS = 1 << BLOCK_BITS;
    reg clock = 0; always #5 clock = ~clock;
    reg reset = 1, write_valid = 0, scan_start = 0, block_ready = 0;
    reg [BLOCK_BITS-1:0] write_block = 0;
    wire block_valid, scan_done, scanning;
    wire [BLOCK_BITS-1:0] block;
    reg random_ready = 0, random_writes = 0;
    integer seed = SEED;

    nexttang_dirty_blocks #(.BLOCK_BITS(BLOCK_BITS)) dut (
        .clock(clock), .reset(reset), .write_valid_in(write_valid), .write_block_in(write_block),
        .scan_start(scan_start), .block_valid(block_valid), .block(block), .block_ready(block_ready),
        .scan_done(scan_done), .scanning(scanning));

    // need[b]: written after it was last taken, so a later scan must report it.
    reg need [0:BLOCKS-1];
    integer k;
    initial for (k = 0; k < BLOCKS; k = k + 1) need[k] = 1;
    always @(posedge clock) begin
        // A write on the take's own clock is covered by the copy that follows
        // the take; a later one is not.
        if (block_valid && block_ready) begin
            $display("T %0d", block);
            need[block] = 0;
        end else if (write_valid)
            need[write_block] = 1;
        if (write_valid && block_valid && block_ready && write_block != block)
            need[write_block] = 1;
        if (scan_done) $display("DONE");
        if (random_ready) block_ready <= $random(seed) & 1;
        if (random_writes) begin
            write_valid <= ($random(seed) & 3) != 0;
            write_block <= $random(seed);
        end
    end

    task write(input integer b); begin
        write_block <= b; write_valid <= 1; @(posedge clock); write_valid <= 0;
    end endtask
    task scan; begin
        scan_start <= 1; @(posedge clock); scan_start <= 0;
        @(posedge clock);
        while (scanning) @(posedge clock);
    end endtask
    task report; integer n; begin
        for (n = 0; n < BLOCKS; n = n + 1) if (need[n]) $display("NEED %0d", n);
    end endtask

    initial begin repeat (400000) @(posedge clock); $display("TIMEOUT"); $finish; end
    initial begin
        repeat (4) @(posedge clock); reset <= 0; @(posedge clock);
"""

TAIL = """
        $display("END");
        $finish;
    end
endmodule
"""


def run(body: str, seed: int = 1) -> list[str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "tb.v").write_text(BENCH.replace("SEED", str(seed)) + body + TAIL, encoding="ascii")
        compiled = subprocess.run(["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o", "tb.vvp", str(RTL), "tb.v"],
                                  cwd=root, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        done = subprocess.run(["vvp", "tb.vvp"], cwd=root, capture_output=True, text=True, timeout=120)
        lines = done.stdout.splitlines()
        if "TIMEOUT" in lines or "END" not in lines:
            raise AssertionError(done.stdout[-2000:])
        return lines


def taken(lines: list[str]) -> list[list[int]]:
    """Blocks taken, one list per scan."""
    scans, now = [], []
    for line in lines:
        if line.startswith("T "):
            now.append(int(line.split()[1]))
        elif line == "DONE":
            scans.append(now)
            now = []
    return scans


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class DirtyBlocksTest(unittest.TestCase):
    def test_first_scan_is_everything_then_only_what_was_written(self) -> None:
        lines = run("""
        block_ready <= 1;
        scan;
        scan;
        write(3); write(7); write(7); write(31); write(0);
        scan;
        scan;
""")
        self.assertEqual(taken(lines), [list(range(32)), [], [0, 3, 7, 31], []])

    def test_a_slow_consumer_holds_the_block(self) -> None:
        lines = run("""
        block_ready <= 1; scan;
        block_ready <= 0;
        write(5); write(9);
        scan_start <= 1; @(posedge clock); scan_start <= 0;
        repeat (100) @(posedge clock);
        if (!block_valid || block != 5) $display("WRONG %0d %0d", block_valid, block);
        block_ready <= 1; @(posedge clock); block_ready <= 0;
        repeat (100) @(posedge clock);
        if (!block_valid || block != 9) $display("WRONG %0d %0d", block_valid, block);
        block_ready <= 1;
        while (scanning) @(posedge clock);
""")
        self.assertFalse([line for line in lines if line.startswith("WRONG")])
        self.assertEqual(taken(lines)[1], [5, 9])

    def test_a_scan_asked_for_during_the_reset_fill_waits(self) -> None:
        lines = run("""
        reset <= 1; @(posedge clock); reset <= 0;
        block_ready <= 1;
        scan;
""")
        self.assertEqual(taken(lines), [list(range(32))])

    def test_no_write_is_lost_under_random_traffic(self) -> None:
        # Writes land at random while scans run with a consumer that stalls
        # at random. Afterwards, with the writes stopped, one scan must take
        # every block written since it was last taken, and the next nothing.
        for seed in (1, 2, 3, 4, 5, 6, 7, 8):
            with self.subTest(seed=seed):
                lines = run("""
        random_ready <= 1; random_writes <= 1;
        repeat (40) scan;
        random_writes <= 0; @(posedge clock); write_valid <= 0; @(posedge clock); @(posedge clock);
        $display("QUIET");
        report;
        random_ready <= 0; block_ready <= 1;
        scan;
        scan;
""", seed)
                quiet = lines.index("QUIET")
                need = {int(line.split()[1]) for line in lines[quiet:] if line.startswith("NEED ")}
                last_two = taken(lines[quiet:])
                self.assertEqual(len(last_two), 2)
                self.assertTrue(need <= set(last_two[0]), (sorted(need), last_two[0]))
                self.assertEqual(last_two[1], [])
                self.assertTrue(need, "the test wrote nothing")


if __name__ == "__main__":
    unittest.main()
