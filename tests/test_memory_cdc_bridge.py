"""Behavioural tests for the one-entry memory CDC mailbox."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CDC_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_memory_cdc_bridge.v"


class MemoryCdcBridgeTest(unittest.TestCase):
    def test_unrelated_clocks_backpressure_and_response_binding(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg source_clock = 0;
    reg source_reset = 1;
    reg source_request = 0;
    wire source_ready;
    reg source_write = 0;
    reg [20:0] source_address = 0;
    reg [7:0] source_write_data = 0;
    wire source_response_valid;
    wire [7:0] source_read_data;
    reg destination_clock = 0;
    reg destination_reset = 1;
    wire destination_request;
    reg destination_ready = 0;
    wire destination_write;
    wire [20:0] destination_address;
    wire [7:0] destination_write_data;
    reg destination_response_valid = 0;
    reg [7:0] destination_read_data = 0;
    integer response_pulses = 0;

    always #7 source_clock = ~source_clock;
    always #11 destination_clock = ~destination_clock;
    always @(posedge source_clock)
        if (source_response_valid)
            response_pulses <= response_pulses + 1;

    nexttang_memory_cdc_bridge dut (
        .source_clock(source_clock), .source_reset(source_reset),
        .source_request(source_request), .source_ready(source_ready),
        .source_write(source_write), .source_address(source_address),
        .source_write_data(source_write_data),
        .source_response_valid(source_response_valid),
        .source_read_data(source_read_data),
        .destination_clock(destination_clock),
        .destination_reset(destination_reset),
        .destination_request(destination_request),
        .destination_ready(destination_ready),
        .destination_write(destination_write),
        .destination_address(destination_address),
        .destination_write_data(destination_write_data),
        .destination_response_valid(destination_response_valid),
        .destination_read_data(destination_read_data)
    );

    task source_issue;
        input write_request;
        input [20:0] address;
        input [7:0] write_data;
        begin
            @(negedge source_clock);
            if (!source_ready)
                $fatal(1, "source mailbox was unexpectedly busy");
            source_write = write_request;
            source_address = address;
            source_write_data = write_data;
            source_request = 1;
            @(negedge source_clock);
            source_request = 0;
        end
    endtask

    task wait_for_destination_request;
        integer cycles;
        begin
            cycles = 0;
            while (!destination_request && cycles < 12) begin
                @(posedge destination_clock);
                #1;
                cycles = cycles + 1;
            end
            if (!destination_request)
                $fatal(1, "request did not cross into destination domain");
        end
    endtask

    task wait_for_source_response;
        integer cycles;
        begin
            cycles = 0;
            while (!source_response_valid && cycles < 12) begin
                @(posedge source_clock);
                #1;
                cycles = cycles + 1;
            end
            if (!source_response_valid)
                $fatal(1, "response did not cross into source domain");
        end
    endtask

    initial begin
        repeat (3) @(posedge source_clock);
        source_reset = 0;
        destination_reset = 0;

        source_issue(0, 21'h12345, 8'h00);
        #1;
        if (source_ready)
            $fatal(1, "source accepted a second request while outstanding");
        source_address = 21'h05555;
        source_write_data = 8'hcc;
        wait_for_destination_request();
        if (destination_write || destination_address != 21'h12345)
            $fatal(1, "read metadata was not bound across the CDC");
        repeat (3) begin
            @(posedge destination_clock);
            #1;
            if (!destination_request || destination_address != 21'h12345)
                $fatal(1, "destination metadata changed under backpressure");
        end

        @(negedge destination_clock);
        destination_ready = 1;
        @(posedge destination_clock);
        #1;
        destination_ready = 0;
        if (destination_request)
            $fatal(1, "accepted destination request remained asserted");
        repeat (2) @(posedge destination_clock);
        @(negedge destination_clock);
        destination_read_data = 8'ha7;
        destination_response_valid = 1;
        @(posedge destination_clock);
        #1;
        destination_response_valid = 0;
        wait_for_source_response();
        if (source_read_data != 8'ha7 || !source_ready)
            $fatal(1, "read response was not returned to its source request");

        source_issue(1, 21'h1a2b3, 8'h5c);
        wait_for_destination_request();
        if (!destination_write || destination_address != 21'h1a2b3 ||
            destination_write_data != 8'h5c)
            $fatal(1, "write metadata was not bound across the CDC");
        @(negedge destination_clock);
        destination_ready = 1;
        destination_response_valid = 1;
        destination_read_data = 8'h00;
        @(posedge destination_clock);
        #1;
        destination_ready = 0;
        destination_response_valid = 0;
        wait_for_source_response();

        repeat (4) @(posedge source_clock);
        #1;
        if (response_pulses != 2)
            $fatal(1, "expected two one-cycle responses, got %0d",
                   response_pulses);

        source_issue(0, 21'h00077, 8'h00);
        wait_for_destination_request();
        #3;
        source_reset = 1;
        destination_reset = 1;
        #1;
        if (!source_ready || destination_request || source_response_valid)
            $fatal(1, "coordinated asynchronous reset did not clear mailbox");
        source_reset = 0;
        destination_reset = 0;

        source_issue(0, 21'h00088, 8'h00);
        wait_for_destination_request();
        @(negedge destination_clock);
        destination_ready = 1;
        @(posedge destination_clock);
        #1;
        destination_ready = 0;
        @(negedge destination_clock);
        destination_read_data = 8'h88;
        destination_response_valid = 1;
        @(posedge destination_clock);
        #1;
        destination_response_valid = 0;
        wait_for_source_response();
        if (source_read_data != 8'h88)
            $fatal(1, "mailbox did not recover after coordinated reset");

        $display("MEMORY_CDC_BRIDGE_PASS");
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
                    "-o", str(simulation_path), str(CDC_RTL),
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
            self.assertIn("MEMORY_CDC_BRIDGE_PASS", simulation_result.stdout)


if __name__ == "__main__":
    unittest.main()
