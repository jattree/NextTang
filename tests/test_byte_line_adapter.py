"""Behavioural tests for byte-to-16-byte memory-line conversion."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ADAPTER_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_byte_line_adapter.v"


class ByteLineAdapterTest(unittest.TestCase):
    def test_all_byte_lanes_and_backpressure(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg byte_request = 0;
    wire byte_ready;
    reg byte_write = 0;
    reg [20:0] byte_address = 0;
    reg [7:0] byte_write_data = 0;
    wire byte_response_valid;
    wire [7:0] byte_read_data;
    wire line_request;
    reg line_ready = 0;
    wire line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    reg line_response_valid = 0;
    reg [127:0] line_read_data = 0;
    integer lane;

    always #5 clock = ~clock;

    nexttang_byte_line_adapter dut (
        .clock(clock), .reset(reset), .byte_request(byte_request),
        .byte_ready(byte_ready), .byte_write(byte_write),
        .byte_address(byte_address), .byte_write_data(byte_write_data),
        .byte_response_valid(byte_response_valid),
        .byte_read_data(byte_read_data), .line_request(line_request),
        .line_ready(line_ready), .line_write(line_write),
        .line_address(line_address), .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data)
    );

    task issue_byte;
        input write_request;
        input [20:0] address;
        input [7:0] write_data;
        begin
            @(negedge clock);
            if (!byte_ready)
                $fatal(1, "adapter was not ready for a new byte request");
            byte_write = write_request;
            byte_address = address;
            byte_write_data = write_data;
            byte_request = 1;
            @(negedge clock);
            byte_request = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        for (lane = 0; lane < 16; lane = lane + 1) begin
            issue_byte(1, 21'h12340 + lane, 8'h80 + lane);
            #1;
            if (!line_request || !line_write || line_address != 17'h01234)
                $fatal(1, "write line metadata was wrong for lane %0d", lane);
            if (line_write_enable != (16'b1 << lane))
                $fatal(1, "write enable was wrong for lane %0d", lane);
            if (line_write_data[lane * 8 +: 8] != 8'h80 + lane)
                $fatal(1, "write data was wrong for lane %0d", lane);
            if (line_write_data & ~(128'hff << (lane * 8)))
                $fatal(1, "inactive write lanes were not zero for lane %0d", lane);

            byte_address = 21'h1fffff;
            byte_write_data = 8'h00;
            repeat (2) @(posedge clock);
            #1;
            if (line_address != 17'h01234 ||
                line_write_enable != (16'b1 << lane))
                $fatal(1, "write metadata changed under backpressure");

            @(negedge clock);
            line_ready = 1;
            line_response_valid = 1;
            @(posedge clock);
            #1;
            line_ready = 0;
            line_response_valid = 0;
            if (!byte_response_valid || !byte_ready)
                $fatal(1, "same-cycle write response was not returned");
        end

        line_read_data = {
            8'h0f, 8'h0e, 8'h0d, 8'h0c, 8'h0b, 8'h0a, 8'h09, 8'h08,
            8'h07, 8'h06, 8'h05, 8'h04, 8'h03, 8'h02, 8'h01, 8'h00
        };
        for (lane = 0; lane < 16; lane = lane + 1) begin
            issue_byte(0, 21'h0abc0 + lane, 8'h00);
            @(negedge clock);
            line_ready = 1;
            @(posedge clock);
            #1;
            line_ready = 0;
            if (!line_request && byte_response_valid)
                $fatal(1, "read completed before response data arrived");
            repeat (lane % 3) @(posedge clock);
            @(negedge clock);
            line_response_valid = 1;
            @(posedge clock);
            #1;
            line_response_valid = 0;
            if (!byte_response_valid || byte_read_data != lane)
                $fatal(1, "read lane %0d returned %02x", lane,
                       byte_read_data);
        end

        issue_byte(0, 21'h0abc7, 8'h00);
        @(negedge clock);
        line_read_data = 128'h7766554433221100_ffeeddccbbaa9988;
        line_ready = 1;
        line_response_valid = 1;
        @(posedge clock);
        #1;
        line_ready = 0;
        line_response_valid = 0;
        if (!byte_response_valid || byte_read_data != 8'hff)
            $fatal(1, "same-cycle read response returned %02x",
                   byte_read_data);

        $display("BYTE_LINE_ADAPTER_PASS");
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
                    "iverilog", "-g2012", "-Wall", "-s", "testbench",
                    "-o", str(simulation_path), str(ADAPTER_RTL),
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
                simulation_result.returncode, 0, simulation_result.stdout
            )
            self.assertIn("BYTE_LINE_ADAPTER_PASS", simulation_result.stdout)


if __name__ == "__main__":
    unittest.main()
