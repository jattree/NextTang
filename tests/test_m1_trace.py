"""The instruction-fetch trace must freeze after its trigger and dump in order.

rtl/smoke/nexttang_m1_trace.v keeps the last opcode-fetch addresses and sends
them over the UART once the trigger address has been fetched and a few more
fetches have followed. The test runs a 16-entry ring with fetches 0x1000,
0x1001, ..., one of them 0x0066, decodes the UART and checks the dump holds
the 16 fetches up to two after the trigger, oldest first.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
TRACE_RTL = REPO_ROOT / "rtl" / "smoke" / "nexttang_m1_trace.v"

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg m1_n = 1;
    reg [15:0] address = 0;
    wire frozen;
    wire transmit;

    nexttang_m1_trace #(
        .CLOCK_HZ(8), .BAUD_RATE(1), .DEPTH_BITS(4), .POST_FETCHES(2),
        .GAP_CLOCKS(50)
    ) dut (
        .clock(clock), .reset(reset), .m1_n(m1_n), .address(address),
        .freeze_request(1'b0), .rearm_request(1'b0),
        .set_trigger(1'b0), .new_trigger(16'h0000),
        .frozen(frozen), .transmit(transmit)
    );

    always #5 clock = !clock;

    task automatic fetch(input [15:0] value);
        begin
            @(negedge clock);
            address = value;
            m1_n = 0;
            repeat (3) @(negedge clock);
            m1_n = 1;
            repeat (2) @(negedge clock);
        end
    endtask

    // UART receiver: 8 clocks per bit.
    reg [7:0] received;
    integer i;
    always begin
        @(negedge transmit);
        repeat (4) @(posedge clock);        // middle of the start bit
        for (i = 0; i < 8; i = i + 1) begin
            repeat (8) @(posedge clock);
            received[i] = transmit;
        end
        repeat (8) @(posedge clock);        // stop bit
        $write("%c", received);
    end

    integer n;
    initial begin
        repeat (3) @(negedge clock);
        reset = 0;
        for (n = 0; n < 30; n = n + 1)
            fetch(16'h1000 + n);
        // A halted CPU fetches one address over and over; only one is kept.
        fetch(16'h101d);
        fetch(16'h101d);
        if (frozen) $fatal(1, "froze without the trigger");
        fetch(16'h0066);
        fetch(16'h0067);
        fetch(16'h0068);
        if (frozen) $fatal(1, "froze before the post-trigger fetches");
        fetch(16'h0069);
        if (!frozen) $fatal(1, "did not freeze");
        // Further fetches must not change the frozen ring.
        fetch(16'h2222);
        fetch(16'h2223);
        // One full dump: 16 lines of 9 bytes and 4 bytes of end, 80 clocks a
        // byte, after the gap.
        repeat (50 + (16 * 9 + 4) * 80 + 200) @(posedge clock);
        $display("");
        $display("TRACE_DONE");
        $finish;
    end
endmodule
"""


class M1TraceTest(unittest.TestCase):
    def test_trace_freezes_after_trigger_and_dumps_oldest_first(self) -> None:
        output = run_testbench(TESTBENCH, TRACE_RTL)
        self.assertIn("TRACE_DONE", output)
        lines = [line.strip() for line in output.splitlines() if line.strip().startswith("T")]
        dump = [line for line in lines if line.startswith("TR ")]
        self.assertEqual(lines[len(dump)], "TE", lines)
        # 30 fetches 0x1000.., the trigger 0x0066, then 0x0067 and 0x0068 are
        # the two post-trigger fetches; 0x0069 freezes it and is recorded too.
        expected = [0x1000 + n for n in range(18, 30)] + [0x0066, 0x0067, 0x0068, 0x0069]
        self.assertEqual([int(line[3:], 16) for line in dump], expected)


if __name__ == "__main__":
    unittest.main()
