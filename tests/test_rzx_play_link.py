"""The RZX play link (rtl/debug/nexttang_rzx_play_link.v): command bytes in,
stream bytes out to a stand-in player, and the bytes it sends the host."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/debug/nexttang_rzx_play_link.v"

BENCH = """
module testbench;
    localparam BIT = 10;
    reg clock = 0;
    always #5 clock = ~clock;
    reg reset = 1, command_valid = 0, cpu_stopped = 1, byte_ready = 0, desync = 0;
    reg [7:0] command_byte = 0;
    reg playing = 0;
    reg [15:0] frames = 0;
    wire taking, play_start, play_stop, byte_valid, busy, tx;
    wire [7:0] byte_out;
    integer out;

    nexttang_rzx_play_link #(.CLOCK_HZ(1000000), .BAUD_RATE(100000), .FIFO_BITS(FIFO_BITS)) dut (
        .clock(clock), .reset(reset), .command_valid(command_valid), .command_byte(command_byte),
        .taking(taking), .cpu_stopped(cpu_stopped), .play_start(play_start), .play_stop(play_stop),
        .playing(playing), .desync(desync), .frames(frames),
        .byte_out(byte_out), .byte_valid(byte_valid), .byte_ready(byte_ready), .busy(busy), .tx(tx));

    // Stand-in player.
    always @(posedge clock) begin
        if (play_start) playing <= 1;
        if (play_stop) playing <= 0;
        if (byte_valid && byte_ready) $fdisplay(out, "B %02x", byte_out);
        if (play_start) $fdisplay(out, "START");
        if (play_stop) $fdisplay(out, "STOP");
    end

    // UART receiver on tx.
    integer k; reg [7:0] rx;
    initial forever begin
        @(negedge tx);
        repeat (BIT / 2) @(posedge clock);
        for (k = 0; k < 8; k = k + 1) begin repeat (BIT) @(posedge clock); rx[k] = tx; end
        repeat (BIT) @(posedge clock);
        $fdisplay(out, "T %02x", rx);
    end

    task send(input [7:0] value); begin
        command_byte <= value; command_valid <= 1; @(posedge clock);
        $fdisplay(out, "S %02x %0d", value, taking);
        command_valid <= 0; repeat (3) @(posedge clock);
    end endtask
    task take(input integer n); integer j; begin
        for (j = 0; j < n; j = j + 1) begin
            wait (byte_valid); @(posedge clock); byte_ready <= 1; @(posedge clock); byte_ready <= 0; @(posedge clock);
        end
    end endtask
    task frame_end; begin frames <= frames + 1; repeat (150) @(posedge clock); end endtask

    initial begin repeat (200000) @(posedge clock); $display("TIMEOUT"); $finish; end
    initial begin
        out = $fopen("out.txt", "w");
        repeat (4) @(posedge clock); reset <= 0; @(posedge clock);
"""

TAIL = """
        repeat (600) @(posedge clock);
        $fdisplay(out, "END taking=%0d busy=%0d playing=%0d", taking, busy, playing);
        $fclose(out);
        $finish;
    end
endmodule
"""


def run(body: str, fifo_bits: int = 4) -> list[str]:
    bench = BENCH.replace("module testbench;", f"module testbench;\n    localparam FIFO_BITS = {fifo_bits};") + body + TAIL
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "tb.v").write_text(bench, encoding="ascii")
        compiled = subprocess.run(["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o", "tb.vvp", str(RTL), "tb.v"],
                                  cwd=root, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        subprocess.run(["vvp", "tb.vvp"], cwd=root, check=True, capture_output=True, timeout=30)
        return (root / "out.txt").read_text().split("\n")[:-1]


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class RzxPlayLinkTest(unittest.TestCase):
    def test_prefill_stream_and_end(self) -> None:
        lines = run("""
        send("P"); send(8'd3); send(8'h11); send("P"); send(8'h33);   // a P inside the prefill is data
        send("K");                                                   // armed: other commands pass by
        cpu_stopped <= 0; repeat (4) @(posedge clock);
        send(8'h44); send(8'hfe); send(8'h00); send("P");
        take(4); frame_end;
        take(2); frame_end; frame_end;
        send(8'hff); send(8'hfe); send(8'h01);
        take(1);
""")
        sent = [line.split() for line in lines if line.startswith("S ")]
        # taking: not for P itself, then count and prefill; not for K; all stream bytes
        self.assertEqual([int(t) for _, _, t in sent], [0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1])
        played = [line for line in lines if line.startswith(("B ", "START", "STOP"))]
        self.assertEqual(played, ["START", "B 11", "B 50", "B 33", "B 44", "B fe", "B 50", "B ff", "STOP"])
        to_host = [int(line.split()[1], 16) for line in lines if line.startswith("T ")]
        # a byte per frame end carrying the count so far, then the three end bytes
        self.assertEqual(to_host[:1], [0x41])
        self.assertEqual(to_host[-3:], [0x80 | 0b100, 3, 0])
        self.assertEqual(to_host[-4] & 0x3F, 3)
        self.assertEqual(lines[-1], "END taking=0 busy=0 playing=0")

    def test_p_is_ignored_while_the_cpu_runs(self) -> None:
        lines = run("""
        cpu_stopped <= 0; repeat (4) @(posedge clock);
        send("P"); send(8'd2); send(8'h11);
""")
        self.assertEqual([line.split()[2] for line in lines if line.startswith("S ")], ["0", "0", "0"])
        self.assertNotIn("START", lines)

    def test_overflow_and_desync_are_reported(self) -> None:
        lines = run("""
        send("P"); send(8'd0);
        cpu_stopped <= 0; repeat (4) @(posedge clock);
        repeat (20) send(8'h22);          // 16-byte buffer plus the output stage
        desync <= 1; playing <= 0;        // the player drops out
""")
        to_host = [int(line.split()[1], 16) for line in lines if line.startswith("T ")]
        self.assertEqual(to_host, [0x80 | 0b011, 0, 0])
        self.assertEqual(lines[-1], "END taking=0 busy=0 playing=0")

    def test_a_second_p_starts_from_an_empty_buffer(self) -> None:
        lines = run("""
        send("P"); send(8'd2); send(8'haa); send(8'hbb);
        send("P"); send(8'd1); send(8'hcc);
        cpu_stopped <= 0; repeat (4) @(posedge clock);
        take(1);
        send(8'hfe); send(8'h01);
""")
        played = [line for line in lines if line.startswith(("B ", "START", "STOP"))]
        self.assertEqual(played, ["START", "B cc", "STOP"])


if __name__ == "__main__":
    unittest.main()
