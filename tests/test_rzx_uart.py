"""The RZX recorder and its UART sender together (rtl/debug/nexttang_rzx_logger.v,
rtl/debug/nexttang_rzx_uart.v), decoded by tools/rzx.py's frames_from_uart."""

from __future__ import annotations

import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.rzx import Frame, frames_from_uart

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [REPO_ROOT / "rtl/debug/nexttang_rzx_logger.v", REPO_ROOT / "rtl/debug/nexttang_rzx_uart.v"]

BENCH = """
module testbench;
    localparam CPU_CLOCKS = 4;
    localparam BIT = 10;               // clocks per bit: CLOCK_HZ 1 MHz, 100 kbaud
    reg clock = 0;
    always #5 clock = ~clock;
    reg reset = 1, start = 0, stop = 0, begin_stream = 0, end_stream = 0;
    reg m1_n = 1, iorq_n = 1, rd_n = 1;
    reg [7:0] data = 8'hff;
    wire [8:0] word;
    wire word_valid, word_ready, recording, saturated, overflow, busy, tx;
    wire [15:0] frames;
    integer out;

    nexttang_rzx_logger #(.FIFO_BITS(FIFO_BITS)) logger (
        .clock(clock), .reset(reset), .start(start), .start_fetches(16'd0), .stop(stop), .recording(recording),
        .m1_n(m1_n), .iorq_n(iorq_n), .rd_n(rd_n), .data(data), .int_n(1'b1),
        .word(word), .word_valid(word_valid), .word_ready(word_ready),
        .frames(frames), .saturated(saturated), .overflow(overflow));
    nexttang_rzx_uart #(.CLOCK_HZ(1000000), .BAUD_RATE(100000)) sender (
        .clock(clock), .reset(reset), .begin_stream(begin_stream), .end_stream(end_stream),
        .end_flags({overflow, saturated}), .end_frames(frames),
        .word(word), .word_valid(word_valid), .word_ready(word_ready), .busy(busy), .tx(tx));

    // UART receiver: sample mid-bit
    integer k; reg [7:0] rx;
    initial begin
        out = $fopen("line.txt", "w");
        forever begin
            @(negedge tx);
            repeat (BIT / 2) @(posedge clock);
            for (k = 0; k < 8; k = k + 1) begin repeat (BIT) @(posedge clock); rx[k] = tx; end
            repeat (BIT) @(posedge clock);
            $fdisplay(out, "%02x", rx);
        end
    end

    task tstates(input integer n); begin repeat (n * CPU_CLOCKS) @(posedge clock); end endtask
    task fetch; begin m1_n <= 0; tstates(2); m1_n <= 1; data <= $random; tstates(2); end endtask
    task in_read(input [7:0] value); begin
        tstates(1); iorq_n <= 0; rd_n <= 0; tstates(2);
        data <= value; tstates(1); iorq_n <= 1; rd_n <= 1; tstates(1);
    end endtask
    task ack; begin
        m1_n <= 0; tstates(2); iorq_n <= 0; tstates(2); m1_n <= 1; iorq_n <= 1; tstates(3);
    end endtask
    task idle(input integer n); begin repeat (n) @(posedge clock); end endtask

    initial begin
        repeat (4) @(posedge clock); reset <= 0;
        @(posedge clock); begin_stream <= 1; start <= 1;
        @(posedge clock); begin_stream <= 0; start <= 0;
"""

TAIL = """
        stop <= 1; @(posedge clock); stop <= 0;
        end_stream <= 1; @(posedge clock); end_stream <= 0;
        wait (!busy);
        repeat (40) @(posedge clock);
        $fclose(out);
        $finish;
    end
endmodule
"""


def run(body: str, fifo_bits: int = 6) -> bytes:
    bench = BENCH.replace("module testbench;", f"module testbench;\n    localparam FIFO_BITS = {fifo_bits};") + body + TAIL
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "tb.v").write_text(bench, encoding="ascii")
        compiled = subprocess.run(["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o", "tb.vvp",
                                   *map(str, SOURCES), "tb.v"], cwd=root, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        subprocess.run(["vvp", "tb.vvp"], cwd=root, check=True, capture_output=True, timeout=600)
        return bytes(int(x, 16) for x in (root / "line.txt").read_text().split())


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class RzxUartTest(unittest.TestCase):
    def test_frames_survive_the_line(self) -> None:
        rng = random.Random(48)
        body, expected = [], []
        for frame_no in range(10):
            fetches, ins = 0, []
            for _ in range(rng.randrange(1, 30)):
                if rng.random() < 0.3:
                    # bytes that need escaping turn up often
                    value = rng.choice([0xFD, 0xFE, 0xFF, rng.randrange(256)])
                    body.append(f"        fetch; in_read(8'h{value:02x});")
                    ins.append(value)
                else:
                    body.append("        fetch;")
                fetches += 1
            if frame_no == 4:
                body.append("        many(300);")   # a fetch count above 255
                fetches += 300
            body.append("        ack; idle(2000);")
            expected.append(Frame(fetches, bytes(ins)))
        body.append("        fetch; in_read(8'h42);")   # cut off by stop
        source = "\n".join(body).replace("many(300);", "repeat (300) fetch;")
        line = run(source + "\n")
        self.assertTrue(line.startswith(b"RZX!"))
        recording = frames_from_uart(b"status text\r\n" + line)
        self.assertTrue(recording.complete)
        self.assertEqual(recording.flags, 0)
        self.assertEqual(recording.frame_count, 10)
        self.assertEqual(recording.frames, expected)

    def test_overflow_is_reported(self) -> None:
        # Reads far faster than the line drains them.
        body = "        repeat (200) begin fetch; in_read(8'h11); end\n        ack;\n"
        recording = frames_from_uart(run(body, fifo_bits=4))
        self.assertTrue(recording.complete)
        self.assertEqual(recording.flags & 2, 2)


if __name__ == "__main__":
    unittest.main()
