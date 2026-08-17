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
DDR3_SDC = REPO_ROOT / "boards" / "console138k" / "console138k_ddr3.sdc"
DDR3_TOP = (
    REPO_ROOT
    / "boards"
    / "console138k"
    / "nexttang_console138k_ddr3_diagnostic.v"
)


class Console138kDdr3PllTest(unittest.TestCase):
    def test_controller_uses_the_physical_50mhz_input(self) -> None:
        top = DDR3_TOP.read_text(encoding="utf-8")
        controller = top.split("DDR3_Memory_Interface_Top ddr3 (", 1)[1]
        controller = controller.split(");", 1)[0]
        self.assertIn(".clk(sys_clk)", controller)

    def test_constraints_describe_the_physical_50mhz_input(self) -> None:
        constraints = DDR3_SDC.read_text(encoding="utf-8")
        self.assertIn(
            "create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]",
            constraints,
        )
        self.assertIn(
            "create_clock -name memory_clock -period 2.500 [get_nets {memory_clock}]",
            constraints,
        )

    def test_generated_wrapper_output_and_clock_gate(self) -> None:
        testbench = r"""
`timescale 1ns/1ps

module Gowin_PLL (
    input  wire clkin,
    input  wire init_clk,
    input  wire enclk0,
    input  wire enclk1,
    input  wire enclk2,
    output wire clkout0,
    output wire clkout1,
    output wire clkout2,
    output wire lock,
    input  wire reset
);
    assign clkout0 = 1'b0;
    assign clkout1 = testbench.source_reference_clock & enclk1;
    assign clkout2 = testbench.source_clock & enclk2;
    assign lock = testbench.source_lock;

    initial begin
        #1;
        if (clkin !== testbench.clock_in ||
            init_clk !== testbench.clock_in ||
            !enclk0 || !enclk1 || reset)
            $fatal(1, "generated DDR3 PLL wrapper contract was wrong");
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
