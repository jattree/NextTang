"""Behavioural contract test for the Console 138K video clock source."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PLL_RTL = (
    REPO_ROOT / "boards" / "console138k" / "nexttang_console138k_pll.v"
)


class Console138kVideoPllTest(unittest.TestCase):
    def test_legal_vco_parameters_and_output_mapping(self) -> None:
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
    assign CLKOUT0 = testbench.source_clock;
    assign CLKOUT1 = 0;
    assign CLKOUT2 = 0;
    assign CLKOUT3 = 0;
    assign CLKOUT4 = 0;
    assign CLKOUT5 = 0;
    assign CLKOUT6 = 0;
    assign CLKFBOUT = 0;
    assign LOCK = testbench.source_lock;

    // Assert the requirement, not the numbers: whatever dividers are chosen,
    // the PFD and VCO must be legal for this device and the pixel clock that
    // comes out after CLKDIV / 5 must be close enough to 74.25 MHz for 720p60.
    real input_mhz, pfd_mhz, vco_mhz, serial_mhz, pixel_mhz, error_percent;

    initial begin
        if (FCLKIN == "50") input_mhz = 50.0;
        else if (FCLKIN == "27") input_mhz = 27.0;
        else $fatal(1, "video PLL input %s is not a clock this board has", FCLKIN);

        if (FBDIV_SEL != 1)
            $fatal(1, "feedback divider must stay at 1 for internal feedback");

        pfd_mhz = input_mhz / IDIV_SEL;
        vco_mhz = pfd_mhz * (MDIV_SEL + MDIV_FRAC_SEL / 8.0);
        serial_mhz = vco_mhz / (ODIV0_SEL + ODIV0_FRAC_SEL / 8.0);
        pixel_mhz = serial_mhz / 5.0;

        if (pfd_mhz < 19.0 || pfd_mhz > 81.25)
            $fatal(1, "PFD %f MHz is outside the 19 to 81.25 MHz range", pfd_mhz);
        if (vco_mhz < 650.0 || vco_mhz > 1300.0)
            $fatal(1, "VCO %f MHz is outside the 650 to 1300 MHz range", vco_mhz);

        error_percent = ((pixel_mhz - 74.25) / 74.25) * 100.0;
        if (error_percent < 0.0) error_percent = -error_percent;
        if (error_percent > 1.0)
            $fatal(1, "pixel clock %f MHz is %f%% from 74.25 MHz, too far for 720p60",
                   pixel_mhz, error_percent);

        if (CLKOUT0_EN != "TRUE" || CLKOUT1_EN != "FALSE" ||
            CLKOUT2_EN != "FALSE" || CLKOUT3_EN != "FALSE" ||
            CLKOUT4_EN != "FALSE" || CLKOUT5_EN != "FALSE" ||
            CLKOUT6_EN != "FALSE")
            $fatal(1, "unexpected video PLL output enable");

        $display("VIDEO_PLL pfd=%0.3f vco=%0.3f serial=%0.3f pixel=%0.4f err=%0.3f%%",
                 pfd_mhz, vco_mhz, serial_mhz, pixel_mhz, error_percent);
    end
endmodule

module testbench;
    reg clock_in = 0;
    reg source_clock = 0;
    reg source_lock = 0;
    wire serial_clock;
    wire locked;

    nexttang_console138k_pll dut (
        .clock_in(clock_in),
        .serial_clock(serial_clock),
        .locked(locked)
    );

    initial begin
        source_lock = 1;
        source_clock = 1;
        #1;
        if (!locked || !serial_clock)
            $fatal(1, "video PLL output or lock mapping was wrong");
        source_clock = 0;
        #1;
        if (serial_clock)
            $fatal(1, "video output did not follow the PLL channel");
        $display("CONSOLE138K_VIDEO_PLL_PASS");
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
            self.assertIn(
                "CONSOLE138K_VIDEO_PLL_PASS", simulation_result.stdout
            )


if __name__ == "__main__":
    unittest.main()
