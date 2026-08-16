"""Behavioural tests for the Gowin DDR3 user-interface adapter."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ADAPTER_RTL = (
    REPO_ROOT / "rtl" / "memory" / "nexttang_gowin_ddr3_ui_adapter.v"
)


class GowinDdr3UiAdapterTest(unittest.TestCase):
    def test_address_mask_and_independent_write_handshakes(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg line_request = 0;
    wire line_ready;
    reg line_write = 0;
    reg [16:0] line_address = 0;
    reg [127:0] line_write_data = 0;
    reg [15:0] line_write_enable = 0;
    wire line_response_valid;
    wire [127:0] line_read_data;
    reg controller_command_ready = 0;
    wire [2:0] controller_command;
    wire controller_command_enable;
    wire [27:0] controller_address;
    reg controller_write_data_ready = 0;
    wire [127:0] controller_write_data;
    wire controller_write_data_enable;
    wire controller_write_data_end;
    wire [15:0] controller_write_data_mask;
    reg [127:0] controller_read_data = 0;
    reg controller_read_data_valid = 0;
    wire controller_burst;

    always #5 clock = ~clock;

    nexttang_gowin_ddr3_ui_adapter dut (
        .clock(clock), .reset(reset), .line_request(line_request),
        .line_ready(line_ready), .line_write(line_write),
        .line_address(line_address), .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .controller_command_ready(controller_command_ready),
        .controller_command(controller_command),
        .controller_command_enable(controller_command_enable),
        .controller_address(controller_address),
        .controller_write_data_ready(controller_write_data_ready),
        .controller_write_data(controller_write_data),
        .controller_write_data_enable(controller_write_data_enable),
        .controller_write_data_end(controller_write_data_end),
        .controller_write_data_mask(controller_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(controller_read_data_valid),
        .controller_burst(controller_burst)
    );

    task issue_line;
        input write_request;
        input [16:0] address;
        begin
            @(negedge clock);
            if (!line_ready)
                $fatal(1, "adapter was not ready for a line request");
            line_write = write_request;
            line_address = address;
            line_request = 1;
            @(negedge clock);
            line_request = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        line_write_data = 128'hffeeddccbbaa99887766554433221100;
        line_write_enable = 16'h0020;
        issue_line(1, 17'h12345);
        #1;
        if (controller_command != 3'b000 ||
            controller_address != {8'b0, 17'h12345, 3'b0})
            $fatal(1, "write command address mapping was wrong");
        if (!controller_command_enable || !controller_write_data_enable ||
            controller_write_data != line_write_data)
            $fatal(1, "write channels were not issued together");
        if (controller_write_data_mask != 16'hffdf)
            $fatal(1, "active-high byte enable was not inverted to mask");
        if (!controller_write_data_end || !controller_burst)
            $fatal(1, "single-burst control signals were not asserted");

        line_address = 0;
        line_write_data = 0;
        line_write_enable = 0;
        @(negedge clock);
        controller_command_ready = 1;
        @(posedge clock);
        #1;
        controller_command_ready = 0;
        if (controller_command_enable || !controller_write_data_enable)
            $fatal(1, "independent command acceptance was not retained");
        if (controller_address != {8'b0, 17'h12345, 3'b0} ||
            controller_write_data_mask != 16'hffdf)
            $fatal(1, "write metadata changed under data backpressure");

        repeat (2) @(posedge clock);
        @(negedge clock);
        controller_write_data_ready = 1;
        @(posedge clock);
        #1;
        controller_write_data_ready = 0;
        if (!line_response_valid || !line_ready)
            $fatal(1, "write did not complete after both channels accepted");

        line_write_data = 128'h00112233445566778899aabbccddeeff;
        line_write_enable = 16'h8000;
        issue_line(1, 17'h00003);
        @(negedge clock);
        controller_write_data_ready = 1;
        @(posedge clock);
        #1;
        controller_write_data_ready = 0;
        if (!controller_command_enable || controller_write_data_enable)
            $fatal(1, "data-first write acceptance was not retained");
        @(negedge clock);
        controller_command_ready = 1;
        @(posedge clock);
        #1;
        controller_command_ready = 0;
        if (!line_response_valid || !line_ready)
            $fatal(1, "data-first write did not complete");

        issue_line(0, 17'h00002);
        #1;
        if (controller_command != 3'b001 ||
            controller_address != 28'h0000010 ||
            !controller_command_enable || controller_write_data_enable)
            $fatal(1, "read command mapping was wrong");
        @(negedge clock);
        controller_command_ready = 1;
        @(posedge clock);
        #1;
        controller_command_ready = 0;
        if (controller_command_enable || line_response_valid)
            $fatal(1, "read command did not wait for return data");

        repeat (3) @(posedge clock);
        @(negedge clock);
        controller_read_data = 128'h0123456789abcdef_fedcba9876543210;
        controller_read_data_valid = 1;
        @(posedge clock);
        #1;
        controller_read_data_valid = 0;
        if (!line_response_valid ||
            line_read_data != 128'h0123456789abcdef_fedcba9876543210)
            $fatal(1, "read response data was not returned");

        issue_line(0, 17'h00004);
        @(negedge clock);
        controller_read_data = 128'hffeeddccbbaa9988_7766554433221100;
        controller_command_ready = 1;
        controller_read_data_valid = 1;
        @(posedge clock);
        #1;
        controller_command_ready = 0;
        controller_read_data_valid = 0;
        if (!line_response_valid ||
            line_read_data != 128'hffeeddccbbaa9988_7766554433221100)
            $fatal(1, "same-cycle read response was not returned");

        $display("GOWIN_DDR3_UI_ADAPTER_PASS");
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
            self.assertIn(
                "GOWIN_DDR3_UI_ADAPTER_PASS", simulation_result.stdout
            )


if __name__ == "__main__":
    unittest.main()
