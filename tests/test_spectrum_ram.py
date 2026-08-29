"""Behavioural proof for the compact 48K Spectrum RAM mapping."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RAM_SOURCE = REPO_ROOT / "rtl" / "memory" / "nexttang_spectrum_ram.v"
BLOCK_RAM_SOURCE = REPO_ROOT / "rtl" / "memory" / "nexttang_block_ram.v"


class SpectrumRamTests(unittest.TestCase):
    def test_first_and_last_machine_addresses_are_independent(self) -> None:
        source = r'''
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg write_enable = 0;
    reg [15:0] write_address = 0;
    reg [7:0] write_data = 0;
    wire [7:0] read_data;
    wire [7:0] port_b_data;

    always #5 clock = !clock;

    nexttang_spectrum_ram dut (
        .clock(clock),
        .write_enable(write_enable),
        .write_address(write_address),
        .write_data(write_data),
        .read_data(read_data),
        .port_b_clock(clock),
        .port_b_address(write_address),
        .port_b_data(port_b_data)
    );

    task write_byte(input [15:0] address, input [7:0] value);
    begin
        @(negedge clock);
        write_address = address;
        write_data = value;
        write_enable = 1;
        @(posedge clock);
        #1;
        write_enable = 0;
    end
    endtask

    task expect_byte(input [15:0] address, input [7:0] value);
    begin
        @(negedge clock);
        write_address = address;
        @(posedge clock);
        #1;
        if (read_data !== value || port_b_data !== value)
            $fatal(1, "address %h: expected %h, got %h/%h",
                   address, value, read_data, port_b_data);
    end
    endtask

    initial begin
        write_byte(16'h4000, 8'h12);
        write_byte(16'hffff, 8'ha5);
        expect_byte(16'h4000, 8'h12);
        expect_byte(16'hffff, 8'ha5);
        $finish;
    end
endmodule
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            testbench = root / "testbench.v"
            executable = root / "testbench"
            testbench.write_text(source, encoding="ascii")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-o", executable,
                 BLOCK_RAM_SOURCE, RAM_SOURCE, testbench],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            run_result = subprocess.run(
                ["vvp", executable],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(run_result.returncode, 0,
                             run_result.stdout + run_result.stderr)


if __name__ == "__main__":
    unittest.main()
