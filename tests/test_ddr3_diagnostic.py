"""Behavioural tests for the destructive 1 GiB DDR3 address diagnostic."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTIC_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_ddr3_diagnostic.v"


def run_testbench(mode: int) -> str:
    testbench = rf"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg calibration_complete = 0;
    reg command_ready = 0;
    wire [2:0] command;
    wire command_enable;
    wire [28:0] address;
    reg write_data_ready = 0;
    wire [255:0] write_data;
    wire write_data_enable;
    wire write_data_end;
    wire [31:0] write_data_mask;
    reg [255:0] read_data = 0;
    reg read_data_valid = 0;
    wire burst;
    wire [2:0] status;
    wire [4:0] failure_expected_index;
    wire [4:0] failure_observed_index;
    reg [255:0] memory [0:26];
    reg pending_read = 0;
    reg [4:0] pending_index = 0;
    integer cycles = 0;
    integer writes = 0;
    integer reads = 0;
    integer delayed_write_countdown = 0;
    reg [255:0] delayed_write_data = 0;

    always #5 clock = ~clock;

    function [4:0] address_index;
        input [28:0] value;
        integer address_bit;
        begin
            address_index = 5'h1f;
            if (value == 29'h00000000)
                address_index = 0;
            else if (value == 29'h0ffffff8)
                address_index = 26;
            else begin
                for (address_bit = 3; address_bit <= 27;
                     address_bit = address_bit + 1) begin
                    if (value == (29'h00000001 << address_bit))
                        address_index = address_bit - 2;
                end
            end
            if (address_index == 5'h1f)
                $fatal(1, "unexpected diagnostic address %h", value);
        end
    endfunction

    nexttang_ddr3_diagnostic #(
        .CALIBRATION_TIMEOUT_CYCLES(8),
        .TRANSACTION_TIMEOUT_CYCLES(12),
        .WRITE_DRAIN_CYCLES(96)
    ) dut (
        .clock(clock), .reset(reset),
        .calibration_complete(calibration_complete),
        .controller_command_ready(command_ready),
        .controller_command(command),
        .controller_command_enable(command_enable),
        .controller_address(address),
        .controller_write_data_ready(write_data_ready),
        .controller_write_data(write_data),
        .controller_write_data_enable(write_data_enable),
        .controller_write_data_end(write_data_end),
        .controller_write_data_mask(write_data_mask),
        .controller_read_data(read_data),
        .controller_read_data_valid(read_data_valid),
        .controller_burst(burst), .status(status),
        .failure_expected_index(failure_expected_index),
        .failure_observed_index(failure_observed_index)
    );

    always @(negedge clock) begin
        cycles = cycles + 1;
        command_ready = 0;
        write_data_ready = 0;
        read_data_valid = 0;

        if (delayed_write_countdown > 0) begin
            delayed_write_countdown = delayed_write_countdown - 1;
            if (delayed_write_countdown == 0)
                memory[26] = delayed_write_data;
        end

        if ({mode} == 0 || {mode} == 1 || {mode} == 4 ||
            {mode} == 5 || {mode} == 6 || {mode} == 7 ||
            {mode} == 8) begin
            if ({mode} == 8 && cycles < 8) begin
                command_ready = cycles[0];
                write_data_ready = !cycles[0];
            end else begin
                command_ready = cycles[0];
                write_data_ready = cycles[0];
            end
            #1;
            if ({mode} == 8 && cycles < 8 &&
                (command_enable || write_data_enable))
                $fatal(1, "write command and data were not issued as a pair");
            if (command_enable && command == 3'b000) begin
                if (!command_ready || !write_data_ready ||
                    !write_data_enable)
                    $fatal(1, "incomplete write pair was accepted");
                writes = writes + 1;
                if ({mode} == 6 && address_index(address) == 26) begin
                    delayed_write_data = write_data;
                    delayed_write_countdown = 80;
                end else if ({mode} == 7 &&
                             address == 29'h08000000) begin
                    memory[0] = write_data;
                end else begin
                    memory[address_index(address)] = write_data;
                end
            end
            if (write_data_enable &&
                !(command_enable && command == 3'b000))
                $fatal(1, "write data was issued without its command");
            if (command_enable && command == 3'b001 && command_ready) begin
                pending_index = ({mode} == 7 &&
                                 address == 29'h08000000)
                    ? 0 : address_index(address);
                reads = reads + 1;
                if ({mode} == 5) begin
                    read_data = memory[address_index(address)];
                    read_data_valid = 1;
                end else begin
                    pending_read = 1;
                end
            end else if (pending_read) begin
                pending_read = 0;
                read_data = memory[pending_index];
                if ({mode} == 1 && pending_index == 3'd5)
                    read_data[17] = ~read_data[17];
                read_data_valid = 1;
            end
            if ({mode} == 4 && writes >= 3)
                calibration_complete = 0;
        end
    end

    initial begin
        memory[26] = 0;
        repeat (2) @(posedge clock);
        reset = 0;
        if ({mode} != 2) begin
            repeat (3) @(posedge clock);
            calibration_complete = 1;
        end

        repeat (300) begin
            @(posedge clock);
            if (status == 3 || status >= 4) begin
                #1;
                if (!write_data_end || write_data_mask != 0 || burst)
                    $fatal(1, "fixed controller controls were wrong");
                if ({mode} == 0 &&
                    (status != 3 || writes != 27 || reads != 27))
                    $fatal(1, "pass path ended with status %0d, writes %0d, reads %0d", status, writes, reads);
                if ({mode} == 1 && status != 4)
                    $fatal(1, "corruption did not produce data error");
                if ({mode} == 2 && status != 5)
                    $fatal(1, "missing calibration did not time out");
                if ({mode} == 3 && status != 6)
                    $fatal(1, "controller backpressure did not time out");
                if ({mode} == 4 && status != 7)
                    $fatal(1, "calibration loss was not reported");
                if ({mode} == 5 &&
                    (status != 3 || writes != 27 || reads != 27))
                    $fatal(1, "same-cycle read path did not pass");
                if ({mode} == 6 &&
                    (status != 3 || writes != 27 || reads != 27))
                    $fatal(1, "accepted write was read before it became visible");
                if ({mode} == 7 && status != 4)
                    $fatal(1, "simulated 512 MB alias was not detected");
                if ({mode} == 7 &&
                    (failure_expected_index != 0 ||
                     failure_observed_index != 25))
                    $fatal(1, "alias detail was expected 0, observed %0d/%0d",
                           failure_expected_index, failure_observed_index);
                if ({mode} == 8 &&
                    (status != 3 || writes != 27 || reads != 27))
                    $fatal(1, "paired write path did not pass");
                $display("DDR3_DIAGNOSTIC_PASS mode={mode} status=%0d", status);
                $finish;
            end
        end
        $fatal(1, "diagnostic did not reach a terminal state");
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
                str(DIAGNOSTIC_RTL),
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
            raise AssertionError(
                simulation_result.stdout + simulation_result.stderr
            )
        return simulation_result.stdout


class Ddr3DiagnosticTest(unittest.TestCase):
    def test_bounded_pass_and_failure_paths(self) -> None:
        for mode in range(9):
            with self.subTest(mode=mode):
                self.assertIn("DDR3_DIAGNOSTIC_PASS", run_testbench(mode))


if __name__ == "__main__":
    unittest.main()
