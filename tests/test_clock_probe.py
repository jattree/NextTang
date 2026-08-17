"""Behavioural tests for the second-clock frequency probe."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PROBE_RTL = REPO_ROOT / "rtl" / "smoke" / "nexttang_clock_probe.v"


def run_testbench(testbench: str) -> str:
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_path = Path(temporary_directory)
        testbench_path = temporary_path / "testbench.v"
        simulation_path = temporary_path / "simulation.vvp"
        testbench_path.write_text(testbench, encoding="utf-8")

        compile_result = subprocess.run(
            [
                "iverilog", "-g2012", "-Wall", "-s", "testbench",
                "-o", str(simulation_path), str(PROBE_RTL), str(testbench_path),
            ],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True,
        )
        if compile_result.returncode:
            raise AssertionError(compile_result.stderr)

        simulation_result = subprocess.run(
            ["vvp", str(simulation_path)],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True,
        )
        if simulation_result.returncode:
            raise AssertionError(simulation_result.stdout + simulation_result.stderr)
        return simulation_result.stdout


# The window is scaled down so the simulation is short.  A 1000-cycle window
# against a measured clock at half the local rate must report about 500.
PREAMBLE = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg measured_clock = 0;
    reg reset = 1;
    wire [31:0] measured_hz;
    wire measured_valid;
    wire [2:0] colour;

    nexttang_clock_probe #(
        .CLOCK_HZ(1000),
        .EXPECT_A_HZ(500),
        .EXPECT_B_HZ(1000),
        .TOLERANCE_DIV(20)
    ) dut (
        .clock(clock), .reset(reset), .measured_clock(measured_clock),
        .measured_hz(measured_hz), .measured_valid(measured_valid),
        .colour(colour)
    );

    always #5 clock = ~clock;
"""


class ClockProbeTest(unittest.TestCase):
    def test_measures_a_half_rate_clock_and_reports_the_expected_colour(self) -> None:
        # Measured clock at half the local rate lands on EXPECT_A, so green.
        output = run_testbench(PREAMBLE + r"""
    always #10 measured_clock = ~measured_clock;

    initial begin
        #40 reset = 0;
        wait (measured_valid);
        #1;
        if (measured_hz < 480 || measured_hz > 520)
            $fatal(1, "half-rate clock measured as %0d, expected about 500", measured_hz);
        if (colour !== 3'b010)
            $fatal(1, "expected green for the reference rate, got %b", colour);
        $display("PROBE_HALF_RATE_PASS %0d", measured_hz);
        $finish;
    end
endmodule
""")
        self.assertIn("PROBE_HALF_RATE_PASS", output)

    def test_reports_red_when_the_measured_clock_is_dead(self) -> None:
        # measured_clock never toggles: the synchroniser never advances, the
        # result stays zero, and that must read as a dead clock rather than as
        # a plausible measurement.
        output = run_testbench(PREAMBLE + r"""
    initial begin
        #40 reset = 0;
        wait (measured_valid);
        #1;
        if (measured_hz != 0)
            $fatal(1, "dead clock measured as %0d, expected 0", measured_hz);
        if (colour !== 3'b100)
            $fatal(1, "expected red for a dead clock, got %b", colour);
        $display("PROBE_DEAD_CLOCK_PASS");
        $finish;
    end
endmodule
""")
        self.assertIn("PROBE_DEAD_CLOCK_PASS", output)

    def test_reports_white_for_an_unexpected_rate(self) -> None:
        # A clock at neither expected rate must be distinguishable from both,
        # so a wrong-but-present reference is not mistaken for the right one.
        output = run_testbench(PREAMBLE + r"""
    always #35 measured_clock = ~measured_clock;

    initial begin
        #40 reset = 0;
        wait (measured_valid);
        #1;
        if (colour !== 3'b111)
            $fatal(1, "expected white for an unexpected rate, got %b at %0d",
                   colour, measured_hz);
        $display("PROBE_UNEXPECTED_RATE_PASS %0d", measured_hz);
        $finish;
    end
endmodule
""")
        self.assertIn("PROBE_UNEXPECTED_RATE_PASS", output)


class SampledClockProbeTest(unittest.TestCase):
    def test_counts_a_slow_signal_without_making_it_a_clock(self) -> None:
        # A vsync-like pulse far slower than the local clock. Sampling mode must
        # count its rising edges, not its level, and must not need the signal to
        # act as a clock.
        output = run_testbench(r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg slow = 0;
    reg reset = 1;
    wire [31:0] measured_hz;
    wire measured_valid;
    wire [2:0] colour;

    nexttang_clock_probe #(
        .CLOCK_HZ(1000),
        .EXPECT_A_HZ(60),
        .EXPECT_B_HZ(50),
        .TOLERANCE_DIV(10),
        .MEASURE_BY_SAMPLING(1)
    ) dut (
        .clock(clock), .reset(reset), .measured_clock(slow),
        .measured_hz(measured_hz), .measured_valid(measured_valid),
        .colour(colour)
    );

    always #5 clock = ~clock;
    // One rising edge every 16 local cycles: about 62 in a 1000-cycle window.
    always #80 slow = ~slow;

    initial begin
        #40 reset = 0;
        wait (measured_valid);
        #1;
        if (measured_hz < 54 || measured_hz > 66)
            $fatal(1, "slow signal measured as %0d, expected about 62", measured_hz);
        if (colour !== 3'b010)
            $fatal(1, "expected green for the 60 Hz band, got %b", colour);
        $display("PROBE_SAMPLED_PASS %0d", measured_hz);
        $finish;
    end
endmodule
""")
        self.assertIn("PROBE_SAMPLED_PASS", output)

    def test_reports_red_when_the_slow_signal_never_moves(self) -> None:
        output = run_testbench(r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    wire [31:0] measured_hz;
    wire measured_valid;
    wire [2:0] colour;

    nexttang_clock_probe #(
        .CLOCK_HZ(1000), .EXPECT_A_HZ(60), .EXPECT_B_HZ(50),
        .TOLERANCE_DIV(10), .MEASURE_BY_SAMPLING(1)
    ) dut (
        .clock(clock), .reset(reset), .measured_clock(1'b0),
        .measured_hz(measured_hz), .measured_valid(measured_valid),
        .colour(colour)
    );

    always #5 clock = ~clock;

    initial begin
        #40 reset = 0;
        wait (measured_valid);
        #1;
        if (colour !== 3'b100)
            $fatal(1, "expected red for a stuck signal, got %b", colour);
        $display("PROBE_SAMPLED_DEAD_PASS");
        $finish;
    end
endmodule
""")
        self.assertIn("PROBE_SAMPLED_DEAD_PASS", output)


if __name__ == "__main__":
    unittest.main()
