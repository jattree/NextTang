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
TREE_RTL = (
    REPO_ROOT / "boards" / "console138k" / "nexttang_console138k_machine_clock_tree.v"
)
RESET_RELEASE_RTL = REPO_ROOT / "rtl" / "reset" / "nexttang_reset_release.v"


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
    parameter CLKOUT2_PE_FINE = 0,
    parameter CLKOUT3_PE_COARSE = 0,
    parameter CLKOUT3_PE_FINE = 0
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
    assign CLKOUT0 = testbench.source_28;
    assign CLKOUT1 = testbench.source_14;
    assign CLKOUT2 = testbench.source_7;
    assign CLKOUT3 = testbench.source_28_n;
    assign CLKOUT4 = 0;
    assign CLKOUT5 = 0;
    assign CLKOUT6 = 0;
    assign CLKFBOUT = 0;
    assign LOCK = testbench.source_lock;

    real input_mhz, pfd_mhz, vco_mhz;

    initial begin
        // Assert the requirement rather than a set of magic numbers: whatever
        // dividers are chosen, the PFD and VCO must be legal for this device
        // and the three machine clocks must come out exactly right.
        if (FCLKIN == "50") input_mhz = 50.0;
        else if (FCLKIN == "27") input_mhz = 27.0;
        else $fatal(1, "machine PLL input %s is not a clock this board has", FCLKIN);

        if (FBDIV_SEL != 1)
            $fatal(1, "feedback divider must stay at 1 for internal feedback");
        if (MDIV_FRAC_SEL != 0)
            $fatal(1, "machine clocks must use an integer feedback divider");

        pfd_mhz = input_mhz / IDIV_SEL;
        vco_mhz = pfd_mhz * MDIV_SEL;
        if (pfd_mhz < 19.0 || pfd_mhz > 81.25)
            $fatal(1, "PFD %f MHz is outside the 19 to 81.25 MHz range", pfd_mhz);
        if (vco_mhz < 650.0 || vco_mhz > 1300.0)
            $fatal(1, "VCO %f MHz is outside the 650 to 1300 MHz range", vco_mhz);

        if (vco_mhz / ODIV0_SEL != 28.0)
            $fatal(1, "CLKOUT0 is %f MHz, not the required 28", vco_mhz / ODIV0_SEL);
        if (vco_mhz / ODIV1_SEL != 14.0)
            $fatal(1, "CLKOUT1 is %f MHz, not the required 14", vco_mhz / ODIV1_SEL);
        if (vco_mhz / ODIV2_SEL != 7.0)
            $fatal(1, "CLKOUT2 is %f MHz, not the required 7", vco_mhz / ODIV2_SEL);
        if (ODIV3_SEL != ODIV0_SEL)
            $fatal(1, "the shifted output must divide the same as CLKOUT0");
        if (CLKOUT0_EN != "TRUE" || CLKOUT1_EN != "TRUE" ||
            CLKOUT2_EN != "TRUE" || CLKOUT3_EN != "TRUE")
            $fatal(1, "a machine-clock output was disabled");
        if (CLKOUT0_PE_COARSE != 0 || CLKOUT0_PE_FINE != 0 ||
            CLKOUT1_PE_COARSE != 0 || CLKOUT1_PE_FINE != 0 ||
            CLKOUT2_PE_COARSE != 0 || CLKOUT2_PE_FINE != 0)
            $fatal(1, "machine-clock phase was not zero");
        if (CLKOUT3_PE_COARSE != 13 || CLKOUT3_PE_FINE != 4)
            $fatal(1, "complementary 28 MHz phase was not 180 degrees");
    end
endmodule

module testbench;
    reg clock_in = 0;
    reg source_28 = 0;
    reg source_28_n = 1;
    reg source_14 = 0;
    reg source_7 = 0;
    reg source_lock = 0;
    wire clock_28;
    wire clock_28_n;
    wire clock_14;
    wire clock_7;
    wire locked;

    nexttang_console138k_machine_pll dut (
        .clock_in(clock_in), .clock_28(clock_28), .clock_28_n(clock_28_n),
        .clock_14(clock_14), .clock_7(clock_7), .locked(locked)
    );

    initial begin
        source_lock = 1;
        source_28 = 1;
        source_28_n = 0;
        source_14 = 1;
        source_7 = 1;
        #1;
        if (!locked)
            $fatal(1, "PLL lock output was not mapped");
        if ({clock_28, clock_28_n, clock_14, clock_7} !== 4'b1011)
            $fatal(1, "machine clocks were mapped to the wrong PLL outputs");
        source_28 = 0;
        source_28_n = 1;
        source_14 = 0;
        source_7 = 0;
        #1;
        if ({clock_28, clock_28_n, clock_14, clock_7} !== 4'b0100)
            $fatal(1, "machine clock output did not follow its mapped channel");
        $display("CONSOLE138K_MACHINE_PLL_PASS");
        $finish;
    end
endmodule
"""
        output = run_testbench(testbench, PLL_RTL)
        self.assertIn("CONSOLE138K_MACHINE_PLL_PASS", output)

    def test_console_clock_tree_reset_and_core_contract(self) -> None:
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
    parameter CLKOUT2_PE_FINE = 0,
    parameter CLKOUT3_PE_COARSE = 0,
    parameter CLKOUT3_PE_FINE = 0
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
    assign CLKOUT0 = testbench.source_28;
    assign CLKOUT1 = testbench.source_14;
    assign CLKOUT2 = testbench.source_7;
    assign CLKOUT3 = testbench.source_28_n;
    assign CLKOUT4 = 0;
    assign CLKOUT5 = 0;
    assign CLKOUT6 = 0;
    assign CLKFBOUT = 0;
    assign LOCK = testbench.source_lock;
endmodule

module DCS #(
    parameter DCS_MODE = "RISING"
) (
    output wire CLKOUT,
    input wire CLKIN0, CLKIN1, CLKIN2, CLKIN3,
    input wire [3:0] CLKSEL,
    input wire SELFORCE
);
    assign CLKOUT = CLKSEL[0] ? CLKIN0 :
                    CLKSEL[1] ? CLKIN1 :
                    CLKSEL[2] ? CLKIN2 :
                    CLKSEL[3] ? CLKIN3 : 1'b0;
endmodule

module testbench;
    reg clock_27 = 0;
    reg source_28 = 0;
    reg source_28_n = 1;
    reg source_14 = 0;
    reg source_7 = 0;
    reg source_lock = 0;
    reg force_reset = 0;
    reg memory_calibrated = 0;
    reg memory_fault = 0;
    reg cpu_clock_lsb = 0;
    reg cpu_contend = 0;
    reg [1:0] cpu_speed = 0;
    wire clock_28, clock_28_n, clock_14, clock_7, clock_3m5;
    wire cpu_clock, psg_enable, machine_reset, clock_locked;
    integer cycle;

    nexttang_console138k_machine_clock_tree #(.RESET_RELEASE_STAGES(3)) dut (
        .clock_27(clock_27), .force_reset(force_reset),
        .memory_calibrated(memory_calibrated), .memory_fault(memory_fault),
        .cpu_clock_lsb(cpu_clock_lsb), .cpu_contend(cpu_contend),
        .cpu_speed(cpu_speed), .clock_28(clock_28),
        .clock_28_n(clock_28_n), .clock_14(clock_14), .clock_7(clock_7),
        .clock_3m5(clock_3m5), .cpu_clock(cpu_clock),
        .psg_enable(psg_enable), .machine_reset(machine_reset),
        .clock_locked(clock_locked)
    );

    task pulse_28;
        begin
            source_28 = 1; source_28_n = 0; #1;
            source_28 = 0; source_28_n = 1; #1;
        end
    endtask

    task pulse_7;
        begin
            source_7 = 1; #1; source_7 = 0; #1;
        end
    endtask

    task release_reset;
        begin
            source_lock = 1;
            memory_calibrated = 1;
            #1;
            for (cycle = 0; cycle < 2; cycle = cycle + 1) begin
                pulse_28();
                if (!machine_reset)
                    $fatal(1, "machine reset released before three clocks");
            end
            pulse_28();
            if (machine_reset)
                $fatal(1, "machine reset did not release after three clocks");
        end
    endtask

    initial begin
        #1;
        if (!machine_reset)
            $fatal(1, "machine reset did not start asserted");
        if (clock_locked)
            $fatal(1, "PLL lock output was not propagated");

        release_reset();
        if (!clock_locked)
            $fatal(1, "PLL lock did not propagate");

        pulse_7();
        if (!clock_3m5)
            $fatal(1, "contended 3.5 MHz clock did not join the tree");
        cpu_speed = 0;
        #1;
        if (!cpu_clock)
            $fatal(1, "slow CPU clock was not selectable");

        cpu_speed = 2'b10;
        source_14 = 1;
        #1;
        if (!cpu_clock)
            $fatal(1, "14 MHz CPU clock was not selectable");
        source_14 = 0;

        memory_fault = 1;
        #1;
        if (!machine_reset || clock_3m5 || psg_enable)
            $fatal(1, "memory fault did not reset the machine tree");
        memory_fault = 0;
        release_reset();

        force_reset = 1;
        #1;
        if (!machine_reset)
            $fatal(1, "forced reset did not assert asynchronously");
        force_reset = 0;
        release_reset();

        memory_calibrated = 0;
        #1;
        if (!machine_reset)
            $fatal(1, "calibration loss did not assert reset");
        memory_calibrated = 1;
        release_reset();

        source_lock = 0;
        #1;
        if (!machine_reset || clock_locked)
            $fatal(1, "PLL lock loss did not assert reset");

        $display("CONSOLE138K_MACHINE_CLOCK_TREE_PASS");
        $finish;
    end
endmodule
"""
        output = run_testbench(
            testbench,
            PLL_RTL,
            TREE_RTL,
            RESET_RELEASE_RTL,
            CONTENTION_RTL,
            ENABLES_RTL,
            MUX_RTL,
        )
        self.assertIn("CONSOLE138K_MACHINE_CLOCK_TREE_PASS", output)


if __name__ == "__main__":
    unittest.main()
