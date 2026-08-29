"""The sticky-event UART reporter must survive the events it is reporting on."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
UART_RTL = REPO_ROOT / "rtl" / "smoke" / "nexttang_debug_status_uart.v"


def run_testbench(body: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        testbench = path / "testbench.v"
        simulation = path / "simulation.vvp"
        testbench.write_text(body, encoding="utf-8")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-Wall", "-s", "testbench",
             "-o", str(simulation), str(UART_RTL), str(testbench)],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True,
        )
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(
            ["vvp", str(simulation)],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


# A receiver that samples the middle of each bit and prints whole lines, so the
# test asserts on decoded text rather than on the transmitter's internal state.
RECEIVER = r"""
    integer bit_number;
    reg [7:0] received;
    reg [8*48-1:0] line;
    integer line_length;

    initial begin
        line_length = 0;
        forever begin
            @(negedge transmit);
            #(BIT_PERIOD * 1.5);
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                received[bit_number] = transmit;
                #(BIT_PERIOD);
            end
            if (received == 8'h0a) begin
                $display("LINE %0s", line);
                line = 0;
                line_length = 0;
            end else if (received != 8'h0d) begin
                line = (line << 8) | received;
                line_length = line_length + 1;
            end
        end
    end
"""


class DebugStatusUartTest(unittest.TestCase):
    def test_flags_cross_through_two_stages_before_sticky_state(self) -> None:
        source = UART_RTL.read_text(encoding="utf-8")
        self.assertIn("flags_meta", source)
        self.assertIn("flags_sync", source)
        self.assertIn("seen <= seen | flags_sync", source)
        self.assertIn("seen & ~flags_sync", source)

    def test_reports_never_seen_then_asserted_then_lost(self) -> None:
        # The three states must be distinguishable in the decoded text, and a
        # flag that went away must not read the same as one that never arrived.
        output = run_testbench(r"""
`timescale 1ns/1ps
module testbench;
    localparam integer CLOCK_HZ = 1000000;
    localparam integer BAUD_RATE = 100000;
    localparam real BIT_PERIOD = 10000.0;   // ns per bit at 100k baud

    reg clock = 0;
    reg reset = 1;
    reg [5:0] flags = 6'b000000;
    wire transmit;

    nexttang_debug_status_uart #(
        .CLOCK_HZ(CLOCK_HZ), .BAUD_RATE(BAUD_RATE), .GAP_CLOCKS(100)
    ) dut (.clock(clock), .reset(reset), .flags(flags), .value(32'h0074_2c40), .transmit(transmit));

    always #500 clock = ~clock;     // 1 MHz
""" + RECEIVER + r"""
    initial begin
        #5000 reset = 0;
        #4000000;                   // a line with nothing asserted
        flags = 6'b000011;            // video and memory PLL lock
        #4000000;
        flags = 6'b000010;            // video PLL drops, memory stays
        #9000000;                   // long enough for a full line to complete
        $finish;
    end
endmodule
""")
        lines = [l.split("LINE ", 1)[1] for l in output.splitlines() if "LINE " in l]
        self.assertTrue(lines, f"no lines decoded from: {output!r}")
        joined = " | ".join(lines)
        self.assertTrue(any(l.startswith("NT ") for l in lines), joined)
        # Nothing asserted at first.
        self.assertTrue(any("V-" in l and "M-" in l for l in lines), joined)
        # Both asserted.
        self.assertTrue(any("V+" in l and "M+" in l for l in lines), joined)
        # Video seen then lost reads '!', and must not be confused with '-'.
        self.assertTrue(any("V!" in l and "M+" in l for l in lines), joined)

    def test_keeps_transmitting_after_a_flag_is_lost(self) -> None:
        # The whole purpose: the log must continue after the event that kills
        # the video output, and the tick counter must keep advancing.
        output = run_testbench(r"""
`timescale 1ns/1ps
module testbench;
    localparam integer CLOCK_HZ = 1000000;
    localparam integer BAUD_RATE = 100000;
    localparam real BIT_PERIOD = 10000.0;

    reg clock = 0;
    reg reset = 1;
    reg [5:0] flags = 6'b000001;
    wire transmit;

    nexttang_debug_status_uart #(
        .CLOCK_HZ(CLOCK_HZ), .BAUD_RATE(BAUD_RATE), .GAP_CLOCKS(100)
    ) dut (.clock(clock), .reset(reset), .flags(flags), .value(32'h0074_2c40), .transmit(transmit));

    always #500 clock = ~clock;
""" + RECEIVER + r"""
    initial begin
        #5000 reset = 0;
        #4000000;
        flags = 6'b000000;            // everything goes away
        #12000000;
        $finish;
    end
endmodule
""")
        lines = [l.split("LINE ", 1)[1] for l in output.splitlines() if "LINE " in l]
        after_loss = [l for l in lines if "V!" in l]
        self.assertGreaterEqual(len(after_loss), 2,
                                f"expected continued reporting after loss: {lines}")
        ticks = [l.split()[-2] for l in after_loss]
        self.assertNotEqual(ticks[0], ticks[-1],
                            f"tick counter did not advance: {ticks}")


if __name__ == "__main__":
    unittest.main()
