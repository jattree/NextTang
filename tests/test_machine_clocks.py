"""Behavioural tests for the portable and Console 138K machine-clock boundary."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ENABLES_RTL = REPO_ROOT / "rtl" / "clock" / "nexttang_machine_clock_enables.v"
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


PSG_TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock_28 = 0;
    reg reset = 1;
    wire psg_enable;
    integer pulse_count = 0;
    integer cycle_count = 0;

    always #1 clock_28 = ~clock_28;

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

    initial begin
        #3 reset = 0;
        while (cycle_count < 33)
            @(posedge clock_28);
        #0.1;
        if (pulse_count != 2)
            $fatal(1, "PSG enable count was %0d instead of 2 in 33 cycles", pulse_count);
        $display("PSG_ENABLE_PASS");
        $finish;
    end
endmodule
"""


class MachineClockTest(unittest.TestCase):
    def test_psg_enable_cadence(self) -> None:
        output = run_testbench(PSG_TESTBENCH, ENABLES_RTL)
        self.assertIn("PSG_ENABLE_PASS", output)

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
    // Outputs 1 and 2, when enabled, divide the same VCO by 2 and 4 of
    // CLKOUT0's divider and start together with it, so 7 MHz rises with 14.
    reg pll_14 = 1'b0;
    reg pll_7 = 1'b0;
    reg [1:0] pll_count = 2'd0;
    always @(posedge testbench.source_28)
        if (testbench.source_lock) begin
            pll_14 <= ~pll_14;
            pll_count <= pll_count + 2'd1;
            if (!pll_count[0])
                pll_7 <= ~pll_7;
        end
    assign CLKOUT1 = CLKOUT1_EN == "TRUE" ? pll_14 : 1'b0;
    assign CLKOUT2 = CLKOUT2_EN == "TRUE" ? pll_7 : 1'b0;
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
        if (ODIV3_SEL != ODIV0_SEL)
            $fatal(1, "the shifted output must divide the same as CLKOUT0");
        if (CLKOUT0_EN != "TRUE" || CLKOUT3_EN != "TRUE")
            $fatal(1, "a machine-clock output was disabled");
        // 14 and 7 MHz are either both divided in fabric or both PLL outputs
        // dividing the same VCO exactly, at phase zero like 28 MHz.
        if (CLKOUT1_EN != CLKOUT2_EN)
            $fatal(1, "14 and 7 MHz must come from the same place");
        if (CLKOUT1_EN == "TRUE") begin
            if (vco_mhz / ODIV1_SEL != 14.0 || vco_mhz / ODIV2_SEL != 7.0)
                $fatal(1, "PLL outputs are %f and %f MHz, not 14 and 7",
                       vco_mhz / ODIV1_SEL, vco_mhz / ODIV2_SEL);
            if (CLKOUT1_PE_COARSE != 0 || CLKOUT1_PE_FINE != 0 ||
                    CLKOUT2_PE_COARSE != 0 || CLKOUT2_PE_FINE != 0)
                $fatal(1, "14 or 7 MHz phase was not zero");
        end
        if (CLKOUT0_PE_COARSE != 0 || CLKOUT0_PE_FINE != 0)
            $fatal(1, "machine-clock phase was not zero");
        // The phase is counted in VCO periods, so it has to be derived from the
        // divider rather than matched as a literal: 13 and 4 were 180 degrees
        // against the old 27 divider and became 194 when the divider moved to
        // 25, unnoticed for two months.
        if ((CLKOUT3_PE_COARSE + CLKOUT3_PE_FINE / 8.0) * 2.0 != ODIV3_SEL)
            $fatal(1, "complementary 28 MHz phase was %f of a period, not a half",
                   (CLKOUT3_PE_COARSE + CLKOUT3_PE_FINE / 8.0) / ODIV3_SEL);
    end
endmodule


module CLKDIV #(parameter DIV_MODE = "2") (
    output reg CLKOUT,
    input wire CALIB,
    input wire HCLKIN,
    input wire RESETN
);
    integer divisor;
    integer count;

    initial begin
        CLKOUT = 1'b0;
        count = 0;
        if (DIV_MODE == "2") divisor = 2;
        else if (DIV_MODE == "4") divisor = 4;
        else if (DIV_MODE == "8") divisor = 8;
        else $fatal(1, "CLKDIV mode %s is not one this board uses", DIV_MODE);
    end

    always @(posedge HCLKIN or negedge RESETN) begin
        if (!RESETN) begin
            count <= 0;
            CLKOUT <= 1'b0;
        end else if (count == divisor / 2 - 1) begin
            count <= 0;
            CLKOUT <= ~CLKOUT;
        end else begin
            count <= count + 1;
        end
    end
endmodule

module testbench;
    reg clock_in = 0;
    reg source_28 = 0;
    reg source_28_n = 1;
    reg source_lock = 0;
    wire clock_28;
    wire clock_28_n;
    wire clock_14;
    wire clock_7;
    wire locked;

    integer edges_28 = 0;
    integer edges_14 = 0;
    integer edges_7 = 0;

    nexttang_console138k_machine_pll #(.PLL_DIVIDERS(PLL_DIVIDERS_UNDER_TEST)) dut (
        .clock_in(clock_in), .clock_28(clock_28), .clock_28_n(clock_28_n),
        .clock_14(clock_14), .clock_7(clock_7), .locked(locked)
    );

    // From PLL outputs, 7 MHz must rise with 14 MHz, as the core assumes.
    // (The CLKDIV model here does not reproduce the hardware's divider phase,
    // which the board reports on its status UART instead.)
    always @(posedge clock_7) begin
        #1;
        if (PLL_DIVIDERS_UNDER_TEST && locked && !clock_14)
            $fatal(1, "7 MHz rose while 14 MHz was low");
    end

    always #5 source_28 = ~source_28;
    always @(*) source_28_n = ~source_28;

    always @(posedge clock_28) edges_28 = edges_28 + 1;
    always @(posedge clock_14) edges_14 = edges_14 + 1;
    always @(posedge clock_7) edges_7 = edges_7 + 1;

    initial begin
        source_lock = 0;
        #200;
        // Held in reset the dividers must not run, or their phase against each
        // other on release is not defined.
        if (edges_14 != 0 || edges_7 != 0)
            $fatal(1, "a divider ran while the PLL was unlocked");
        if (!clock_28)
            ;
        source_lock = 1;
        #100;
        edges_28 = 0;
        edges_14 = 0;
        edges_7 = 0;
        #10000;
        if (!locked)
            $fatal(1, "PLL lock output was not mapped");
        if (edges_28 == 0)
            $fatal(1, "28 MHz was not mapped to CLKOUT0");
        // 14 and 7 are divided from the same source and released together, so
        // the counts must stand in exact ratio rather than merely be close.
        if (edges_14 * 2 < edges_28 - 2 || edges_14 * 2 > edges_28 + 2)
            $fatal(1, "14 MHz is not half of 28: %0d against %0d",
                   edges_14, edges_28);
        if (edges_7 * 4 < edges_28 - 4 || edges_7 * 4 > edges_28 + 4)
            $fatal(1, "7 MHz is not a quarter of 28: %0d against %0d",
                   edges_7, edges_28);
        $display("CONSOLE138K_MACHINE_PLL_PASS");
        $finish;
    end
endmodule
"""
        for pll_dividers in (0, 1):
            with self.subTest(pll_dividers=pll_dividers):
                output = run_testbench(
                    testbench.replace("PLL_DIVIDERS_UNDER_TEST", str(pll_dividers)), PLL_RTL)
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
    assign CLKOUT1 = 1'b0;
    assign CLKOUT2 = 1'b0;
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


module CLKDIV #(parameter DIV_MODE = "2") (
    output reg CLKOUT,
    input wire CALIB,
    input wire HCLKIN,
    input wire RESETN
);
    integer divisor;
    integer count;

    initial begin
        CLKOUT = 1'b0;
        count = 0;
        if (DIV_MODE == "2") divisor = 2;
        else if (DIV_MODE == "4") divisor = 4;
        else if (DIV_MODE == "8") divisor = 8;
        else $fatal(1, "CLKDIV mode %s is not one this board uses", DIV_MODE);
    end

    always @(posedge HCLKIN or negedge RESETN) begin
        if (!RESETN) begin
            count <= 0;
            CLKOUT <= 1'b0;
        end else if (count == divisor / 2 - 1) begin
            count <= 0;
            CLKOUT <= ~CLKOUT;
        end else begin
            count <= count + 1;
        end
    end
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
    wire clock_28, clock_28_n, clock_14, clock_7;
    wire psg_enable, machine_reset, clock_locked;
    integer cycle;

    nexttang_console138k_machine_clock_tree #(.RESET_RELEASE_STAGES(3)) dut (
        .clock_27(clock_27), .force_reset(force_reset),
        .memory_calibrated(memory_calibrated), .memory_fault(memory_fault),
        .clock_28(clock_28),
        .clock_28_n(clock_28_n), .clock_14(clock_14), .clock_7(clock_7),
        .psg_enable(psg_enable), .machine_reset(machine_reset),
        .clock_locked(clock_locked)
    );

    task pulse_28;
        begin
            source_28 = 1; source_28_n = 0; #1;
            source_28 = 0; source_28_n = 1; #1;
        end
    endtask

    // 7 MHz is divided from 28 now, so it is stepped by running its source.
    task pulse_7;
        begin
            pulse_28();
            pulse_28();
            pulse_28();
            pulse_28();
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

        memory_fault = 1;
        #1;
        if (!machine_reset || psg_enable)
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
            ENABLES_RTL,
        )
        self.assertIn("CONSOLE138K_MACHINE_CLOCK_TREE_PASS", output)


if __name__ == "__main__":
    unittest.main()
