"""The dirty-block count on the debug UART (rtl/debug/nexttang_dirty_probe.v)."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [REPO_ROOT / "rtl/debug/nexttang_dirty_blocks.v", REPO_ROOT / "rtl/debug/nexttang_dirty_probe.v"]

BENCH = """
`timescale 1ns/1ps
module testbench;
    localparam BIT = 10;
    reg clock = 0; always #5 clock = ~clock;
    reg reset = 1, request = 0, write_valid = 0;
    reg [20:0] write_address = 0;
    wire tx;
    nexttang_dirty_probe #(.CLOCK_HZ(1000000), .BAUD_RATE(100000)) dut (
        .clock(clock), .reset(reset), .request(request),
        .write_valid(write_valid), .write_address(write_address), .tx(tx));

    integer k; reg [7:0] rx;
    initial forever begin
        @(negedge tx);
        repeat (BIT / 2) @(posedge clock);
        for (k = 0; k < 8; k = k + 1) begin repeat (BIT) @(posedge clock); rx[k] = tx; end
        repeat (BIT) @(posedge clock);
        $write("%c", rx);
    end
    task write(input [20:0] a); begin
        write_address <= a; write_valid <= 1; @(posedge clock); write_valid <= 0;
    end endtask
    task ask; begin
        request <= 1; @(posedge clock); request <= 0;
        repeat (40000) @(posedge clock);
    end endtask
    integer n;
    initial begin
        repeat (4) @(posedge clock); reset <= 0;
        repeat (9000) @(posedge clock);       // the fill after reset
        ask;                                  // everything
        ask;                                  // nothing
        write(21'h000000); write(21'h0000ff); write(21'h000100); write(21'h1fffff); write(21'h054000);
        ask;                                  // four blocks
        for (n = 0; n < 300; n = n + 1) write(n * 256 + 7);
        ask;                                  // 300 blocks
        $finish;
    end
endmodule
"""


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class DirtyProbeTest(unittest.TestCase):
    def test_counts_blocks_written_between_requests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tb.v").write_text(BENCH, encoding="ascii")
            compiled = subprocess.run(["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o", "tb.vvp",
                                       *map(str, SOURCES), "tb.v"], cwd=root, capture_output=True, text=True)
            if compiled.returncode:
                raise AssertionError(compiled.stderr)
            done = subprocess.run(["vvp", "tb.vvp"], cwd=root, capture_output=True, text=True, timeout=120)
        self.assertEqual(done.stdout.split()[:4], ["d2000", "d0000", "d0004", "d012C"])


if __name__ == "__main__":
    unittest.main()
