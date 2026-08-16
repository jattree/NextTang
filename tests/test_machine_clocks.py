"""Behavioural tests for the portable and Console 138K machine-clock boundary."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CONTENTION_RTL = REPO_ROOT / "rtl" / "clock" / "nexttang_cpu_clock_contention.v"
ENABLES_RTL = REPO_ROOT / "rtl" / "clock" / "nexttang_machine_clock_enables.v"
MUX_RTL = REPO_ROOT / "boards" / "console138k" / "nexttang_console138k_cpu_clock_mux.v"


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


if __name__ == "__main__":
    unittest.main()
