"""Behavioural tests for the portable and Console 138K machine-clock boundary."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CONTENTION_RTL = REPO_ROOT / "rtl" / "clock" / "nexttang_cpu_clock_contention.v"
ENABLES_RTL = REPO_ROOT / "rtl" / "clock" / "nexttang_machine_clock_enables.v"
MUX_RTL = REPO_ROOT / "boards" / "console138k" / "nexttang_console138k_cpu_clock_mux.v"
PLL_RTL = REPO_ROOT / "boards" / "console138k" / "nexttang_console138k_machine_pll.v"


def run_testbench(testbench: str, *sources: Path) -> str:
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
                *(str(source) for source in sources),
                str(testbench_path),
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if compile_result.returncode:
            raise AssertionError(compile_result.stderr)

        simulation_result = subprocess.run(
            ["vvp", str(simulation_path)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if simulation_result.returncode:
            raise AssertionError(simulation_result.stdout + simulation_result.stderr)
        return simulation_result.stdout


class MachineClockTest(unittest.TestCase):
    def test_contention_hold_and_psg_enable_cadence(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock_7 = 0;
    reg clock_28 = 0;
    reg reset = 1;
    reg cpu_clock_lsb = 0;
    reg cpu_contend = 0;
    wire clock_3m5;
    wire psg_enable;
    integer pulse_count = 0;
    integer cycle_count = 0;

    always #4 clock_7 = ~clock_7;
    always #1 clock_28 = ~clock_28;

    nexttang_cpu_clock_contention contention (
        .clock_7(clock_7), .reset(reset),
        .cpu_clock_lsb(cpu_clock_lsb), .cpu_contend(cpu_contend),
        .clock_3m5(clock_3m5)
    );

    nexttang_machine_clock_enables enables (
        .clock_28(clock_28), .reset(reset), .psg_enable(psg_enable)
    );

    always @(posedge clock_28) begin
        if (!reset) begin
            cycle_count = cycle_count + 1;
            if (psg_enable)
                pulse_count = pulse_count + 1;
        end
    end

    task clock_7_step;
        begin
            @(posedge clock_7); #1;
        end
    endtask

    initial begin
        #1;
        if (clock_3m5 !== 1'b0)
            $fatal(1, "contention clock did not reset low");

        #2 reset = 0;
        cpu_clock_lsb = 0;
        clock_7_step();
        if (!clock_3m5)
            $fatal(1, "low CPU phase did not raise the 3.5 MHz clock");

        cpu_clock_lsb = 1;
        cpu_contend = 1;
        clock_7_step();
        if (!clock_3m5)
            $fatal(1, "contention failed to hold the high phase");

        cpu_contend = 0;
        clock_7_step();
        if (clock_3m5)
            $fatal(1, "uncontended high CPU phase did not lower the clock");

        cpu_contend = 1;
        clock_7_step();
        if (clock_3m5)
            $fatal(1, "contention failed to hold the low phase");

        cpu_clock_lsb = 0;
        clock_7_step();
        if (!clock_3m5)
            $fatal(1, "clock failed to resume after contention");

        #1 reset = 1;
        #1;
        if (clock_3m5 !== 1'b0)
            $fatal(1, "asynchronous reset did not clear the contention clock");
        reset = 0;

        while (cycle_count < 33)
            @(posedge clock_28);
        #1;
        if (pulse_count != 2)
            $fatal(1, "PSG enable count was %0d instead of 2 in 33 cycles", pulse_count);

        $display("MACHINE_CLOCK_CONTROL_PASS");
        $finish;
    end
endmodule
"""
        output = run_testbench(testbench, CONTENTION_RTL, ENABLES_RTL)
        self.assertIn("MACHINE_CLOCK_CONTROL_PASS", output)

    def test_console_mux_maps_every_speed_to_its_clock(self) -> None:
        testbench = r"""
`timescale 1ns/1ps

module DCS #(
    parameter DCS_MODE = "RISING"
) (
    output wire CLKOUT,
    input wire CLKIN0,
    input wire CLKIN1,
    input wire CLKIN2,
    input wire CLKIN3,
    input wire [3:0] CLKSEL,
    input wire SELFORCE
);
    assign CLKOUT = CLKSEL[0] ? CLKIN0 :
                    CLKSEL[1] ? CLKIN1 :
                    CLKSEL[2] ? CLKIN2 :
                    CLKSEL[3] ? CLKIN3 : 1'b0;
endmodule

module testbench;
    reg clock_3m5 = 0;
    reg clock_7 = 0;
    reg clock_14 = 0;
    reg clock_28 = 0;
    reg [1:0] cpu_speed = 0;
    wire cpu_clock;

    nexttang_console138k_cpu_clock_mux dut (
        .clock_3m5(clock_3m5), .clock_7(clock_7),
        .clock_14(clock_14), .clock_28(clock_28),
        .cpu_speed(cpu_speed), .cpu_clock(cpu_clock)
    );

    task expect_selected;
        input [1:0] speed;
        begin
            cpu_speed = speed;
            {clock_28, clock_14, clock_7, clock_3m5} = 4'b0000;
            #1;
            if (cpu_clock !== 1'b0)
                $fatal(1, "speed %0d did not start low", speed);
            case (speed)
                2'b00: clock_3m5 = 1;
                2'b01: clock_7 = 1;
                2'b10: clock_14 = 1;
                2'b11: clock_28 = 1;
            endcase
            #1;
            if (cpu_clock !== 1'b1)
                $fatal(1, "speed %0d selected the wrong input", speed);
            {clock_28, clock_14, clock_7, clock_3m5} = 4'b1111;
            case (speed)
                2'b00: clock_3m5 = 0;
                2'b01: clock_7 = 0;
                2'b10: clock_14 = 0;
                2'b11: clock_28 = 0;
            endcase
            #1;
            if (cpu_clock !== 1'b0)
                $fatal(1, "speed %0d leaked an unselected input", speed);
        end
    endtask

    initial begin
        expect_selected(2'b00);
        expect_selected(2'b01);
        expect_selected(2'b10);
        expect_selected(2'b11);
        $display("CONSOLE138K_CPU_CLOCK_MUX_PASS");
        $finish;
    end
endmodule
"""
        output = run_testbench(testbench, MUX_RTL)
        self.assertIn("CONSOLE138K_CPU_CLOCK_MUX_PASS", output)

    def test_console_pll_parameters_and_output_mapping(self) -> None:
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
    parameter CLKFB_SEL = "INTERNAL",
    parameter DYN_DPA_EN = "FALSE",
    parameter CLKOUT0_PE_COARSE = 0,
    parameter CLKOUT0_PE_FINE = 0,
    parameter CLKOUT1_PE_COARSE = 0,
    parameter CLKOUT1_PE_FINE = 0,
    parameter CLKOUT2_PE_COARSE = 0,
    parameter CLKOUT2_PE_FINE = 0
) (
    output wire CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6,
    output wire CLKFBOUT, LOCK,
    input wire CLKIN, CLKFB, RESET, PLLPWD, RESET_I, RESET_O,
    input wire [5:0] FBDSEL, IDSEL, ICPSEL,
    input wire [6:0] MDSEL, ODSEL0, ODSEL1, ODSEL2, ODSEL3, ODSEL4, ODSEL5,
    input wire [6:0] ODSEL6, SSCMDSEL,
    input wire [2:0] MDSEL_FRAC, ODSEL0_FRAC, LPFRES, PSSEL, SSCMDSEL_FRAC,
    input wire [3:0] DT0, DT1, DT2, DT3,
    input wire [1:0] LPFCAP,
    input wire PSDIR, PSPULSE, ENCLK0, ENCLK1, ENCLK2, ENCLK3,
    input wire ENCLK4, ENCLK5, ENCLK6, SSCPOL, SSCON
);
    assign CLKOUT0 = CLKIN;
    assign CLKOUT1 = CLKIN;
    assign CLKOUT2 = CLKIN;
    assign CLKOUT3 = 0;
    assign CLKOUT4 = 0;
    assign CLKOUT5 = 0;
    assign CLKOUT6 = 0;
    assign CLKFBOUT = 0;
    assign LOCK = !RESET && !PLLPWD;

    initial begin
        if (FCLKIN != "27" || IDIV_SEL != 1 || FBDIV_SEL != 1)
            $fatal(1, "unexpected PLL input or feedback parameters");
        if (MDIV_SEL != 28 || MDIV_FRAC_SEL != 0)
            $fatal(1, "unexpected 756 MHz VCO parameters");
        if (ODIV0_SEL != 27 || ODIV1_SEL != 54 || ODIV2_SEL != 108)
            $fatal(1, "unexpected machine-clock output dividers");
        if (CLKOUT0_EN != "TRUE" || CLKOUT1_EN != "TRUE" || CLKOUT2_EN != "TRUE")
            $fatal(1, "a machine-clock output was disabled");
        if (CLKOUT0_PE_COARSE != 0 || CLKOUT0_PE_FINE != 0 ||
            CLKOUT1_PE_COARSE != 0 || CLKOUT1_PE_FINE != 0 ||
            CLKOUT2_PE_COARSE != 0 || CLKOUT2_PE_FINE != 0)
            $fatal(1, "machine-clock phase was not zero");
    end
endmodule

module testbench;
    reg clock_in = 0;
    wire clock_28;
    wire clock_14;
    wire clock_7;
    wire locked;

    nexttang_console138k_machine_pll dut (
        .clock_in(clock_in), .clock_28(clock_28), .clock_14(clock_14),
        .clock_7(clock_7), .locked(locked)
    );

    initial begin
        #1;
        if (!locked)
            $fatal(1, "PLL lock output was not mapped");
        clock_in = 1;
        #1;
        if ({clock_28, clock_14, clock_7} !== 3'b111)
            $fatal(1, "machine clocks were mapped to the wrong PLL outputs");
        clock_in = 0;
        #1;
        if ({clock_28, clock_14, clock_7} !== 3'b000)
            $fatal(1, "machine clock output did not follow its mapped channel");
        $display("CONSOLE138K_MACHINE_PLL_PASS");
        $finish;
    end
endmodule
"""
        output = run_testbench(testbench, PLL_RTL)
        self.assertIn("CONSOLE138K_MACHINE_PLL_PASS", output)


if __name__ == "__main__":
    unittest.main()
