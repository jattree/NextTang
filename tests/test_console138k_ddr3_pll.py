"""Behavioural contract test for the Console 138K DDR3 clock source."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PLL_RTL = (
    REPO_ROOT
    / "boards"
    / "console138k"
    / "nexttang_console138k_ddr3_pll.v"
)


class Console138kDdr3PllTest(unittest.TestCase):
    def test_parameters_output_and_clock_gate(self) -> None:
        testbench = r"""
`timescale 1ns/1ps

module PLL #(
    parameter FCLKIN = "100",
    parameter IDIV_SEL = 1,
    parameter FBDIV_SEL = 1,
    parameter ODIV0_SEL = 8,
    parameter ODIV1_SEL = 8,
    parameter ODIV2_SEL = 8,
    parameter ODIV3_SEL = 8,
    parameter ODIV4_SEL = 8,
    parameter ODIV5_SEL = 8,
    parameter ODIV6_SEL = 8,
    parameter MDIV_SEL = 8,
    parameter MDIV_FRAC_SEL = 0,
    parameter ODIV0_FRAC_SEL = 0,
    parameter CLKOUT0_EN = "TRUE",
    parameter CLKOUT1_EN = "FALSE",
    parameter CLKOUT2_EN = "FALSE",
    parameter CLKOUT3_EN = "FALSE",
    parameter CLKOUT4_EN = "FALSE",
    parameter CLKOUT5_EN = "FALSE",
    parameter CLKOUT6_EN = "FALSE",
    parameter CLKFB_SEL = "INTERNAL"
) (
    output wire CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3,
    output wire CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT, LOCK,
    input wire CLKIN, CLKFB, RESET, PLLPWD, RESET_I, RESET_O,
    input wire [5:0] FBDSEL, IDSEL, ICPSEL,
    input wire [6:0] MDSEL, ODSEL0, ODSEL1, ODSEL2, ODSEL3,
    input wire [6:0] ODSEL4, ODSEL5, ODSEL6, SSCMDSEL,
    input wire [2:0] MDSEL_FRAC, ODSEL0_FRAC, LPFRES,
    input wire [2:0] PSSEL, SSCMDSEL_FRAC,
    input wire [3:0] DT0, DT1, DT2, DT3,
    input wire [1:0] LPFCAP,
    input wire PSDIR, PSPULSE, ENCLK0, ENCLK1, ENCLK2,
    input wire ENCLK3, ENCLK4, ENCLK5, ENCLK6, SSCPOL, SSCON
);
    assign CLKOUT0 = testbench.source_clock & ENCLK0;
    assign CLKOUT1 = testbench.source_reference_clock;
    assign CLKOUT2 = 0;
    assign CLKOUT3 = 0;
    assign CLKOUT4 = 0;
    assign CLKOUT5 = 0;
    assign CLKOUT6 = 0;
    assign CLKFBOUT = 0;
    assign LOCK = testbench.source_lock;

    initial begin
        if (FCLKIN != "27" || IDIV_SEL != 1 || FBDIV_SEL != 1)
            $fatal(1, "unexpected DDR3 PLL input parameters");
        if (MDIV_SEL != 29 || MDIV_FRAC_SEL != 5 ||
            ODIV0_SEL != 2 || ODIV0_FRAC_SEL != 0 || ODIV1_SEL != 8)
            $fatal(1, "unexpected DDR3 PLL frequency parameters");
        if (CLKOUT0_EN != "TRUE" || CLKOUT1_EN != "TRUE" ||
            CLKOUT2_EN != "FALSE" || CLKOUT3_EN != "FALSE" ||
            CLKOUT4_EN != "FALSE" || CLKOUT5_EN != "FALSE" ||
            CLKOUT6_EN != "FALSE")
            $fatal(1, "unexpected DDR3 PLL output enable");
    end
endmodule

module testbench;
    reg clock_in = 0;
    reg clock_enable = 0;
    reg source_clock = 0;
    reg source_reference_clock = 0;
    reg source_lock = 0;
    wire memory_clock;
    wire reference_clock;
    wire locked;

    nexttang_console138k_ddr3_pll dut (
        .clock_in(clock_in),
        .clock_enable(clock_enable),
        .memory_clock(memory_clock),
        .reference_clock(reference_clock),
        .locked(locked)
    );

    initial begin
        source_lock = 1;
        source_clock = 1;
        source_reference_clock = 1;
        #1;
        if (!locked || memory_clock || !reference_clock)
            $fatal(1, "disabled DDR3 clock or lock mapping was wrong");
        clock_enable = 1;
        #1;
        if (!memory_clock)
            $fatal(1, "enabled DDR3 clock did not reach the output");
        source_clock = 0;
        source_reference_clock = 0;
        #1;
        if (memory_clock || reference_clock)
            $fatal(1, "DDR3 output did not follow the PLL channel");
        $display("CONSOLE138K_DDR3_PLL_PASS");
        $finish;
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.v"
            simulation_path = temporary_path / "simulation.vvp"
            testbench_path.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                [
                    "iverilog",
                    "-g2012",
                    "-Wall",
                    "-s",
                    "testbench",
                    "-o",
                    str(simulation_path),
                    str(PLL_RTL),
                    str(testbench_path),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            simulation_result = subprocess.run(
                ["vvp", str(simulation_path)],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                simulation_result.returncode,
                0,
                simulation_result.stdout + simulation_result.stderr,
            )
            self.assertIn("CONSOLE138K_DDR3_PLL_PASS", simulation_result.stdout)


if __name__ == "__main__":
    unittest.main()
