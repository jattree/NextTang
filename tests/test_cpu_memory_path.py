"""End-to-end behavioural test for the portable CPU memory path."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
MEMORY_RTL = [
    REPO_ROOT / "rtl" / "memory" / "nexttang_cpu_memory_service.v",
    REPO_ROOT / "rtl" / "memory" / "nexttang_memory_cdc_bridge.v",
    REPO_ROOT / "rtl" / "memory" / "nexttang_byte_line_adapter.v",
    REPO_ROOT / "rtl" / "memory" / "nexttang_cpu_memory_path.v",
]


class CpuMemoryPathTest(unittest.TestCase):
    def test_delayed_read_write_and_read_back(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg machine_clock = 0;
    reg machine_reset = 1;
    reg memory_available = 0;
    reg core_request = 0;
    reg core_read_n = 0;
    reg [20:0] core_address = 0;
    reg [7:0] core_write_data = 0;
    wire [7:0] core_read_data;
    wire core_wait;
    wire core_complete;
    reg memory_clock = 0;
    reg memory_reset = 1;
    wire line_request;
    reg line_ready = 0;
    wire line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    reg line_response_valid = 0;
    reg [127:0] line_read_data = 0;
    wire fault_timeout;
    wire fault_overrun;
    wire fault_calibration_lost;

    reg [127:0] memory_line = {
        8'hff, 8'hee, 8'hdd, 8'hcc, 8'hbb, 8'haa, 8'h99, 8'h88,
        8'h77, 8'h66, 8'h55, 8'h44, 8'h33, 8'h22, 8'h11, 8'h00
    };
    reg pending_response = 0;
    reg [2:0] response_delay = 0;
    integer lane;

    always #9 machine_clock = ~machine_clock;
    always #7 memory_clock = ~memory_clock;

    nexttang_cpu_memory_path #(.MAX_WAIT_CYCLES(64)) dut (
        .machine_clock(machine_clock), .machine_reset(machine_reset),
        .memory_available(memory_available), .core_request(core_request),
        .core_read_n(core_read_n), .core_address(core_address),
        .core_write_data(core_write_data), .core_read_data(core_read_data),
        .core_wait(core_wait), .core_complete(core_complete),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .line_request(line_request), .line_ready(line_ready),
        .line_write(line_write), .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data), .fault_timeout(fault_timeout),
        .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

    always @(posedge memory_clock) begin
        line_response_valid <= 1'b0;
        if (line_request && line_ready) begin
            if (line_address != 17'h01234)
                $fatal(1, "unexpected line address %05x", line_address);
            if (line_write) begin
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (line_write_enable[lane])
                        memory_line[lane * 8 +: 8]
                            <= line_write_data[lane * 8 +: 8];
            end
            pending_response <= 1'b1;
            response_delay <= 3;
        end else if (pending_response && response_delay != 0) begin
            response_delay <= response_delay - 1'b1;
        end else if (pending_response) begin
            line_read_data <= memory_line;
            line_response_valid <= 1'b1;
            pending_response <= 1'b0;
        end
    end

    task core_issue;
        input read_n;
        input [20:0] address;
        input [7:0] write_data;
        begin
            @(negedge machine_clock);
            core_read_n = read_n;
            core_address = address;
            core_write_data = write_data;
            core_request = 1;
            @(negedge machine_clock);
            core_request = 0;
        end
    endtask

    task wait_for_completion;
        integer cycles;
        begin
            cycles = 0;
            while (!core_complete && cycles < 64) begin
                @(posedge machine_clock);
                #1;
                cycles = cycles + 1;
            end
            if (!core_complete)
                $fatal(1, "CPU transaction did not complete");
            if (fault_timeout || fault_overrun || fault_calibration_lost)
                $fatal(1, "CPU memory path raised a fault");
        end
    endtask

    initial begin
        repeat (3) @(posedge machine_clock);
        machine_reset = 0;
        memory_reset = 0;
        memory_available = 1;
        line_ready = 0;
        repeat (2) @(posedge machine_clock);
        #1;
        if (core_wait)
            $fatal(1, "core remained held after memory became available");

        core_issue(0, 21'h12345, 8'h00);
        repeat (5) @(posedge memory_clock);
        line_ready = 1;
        wait_for_completion();
        if (core_read_data != 8'h55)
            $fatal(1, "initial read returned %02x", core_read_data);

        core_issue(1, 21'h12345, 8'ha5);
        wait_for_completion();
        if (memory_line[5 * 8 +: 8] != 8'ha5)
            $fatal(1, "masked byte write did not update lane five");
        if (memory_line[4 * 8 +: 8] != 8'h44 ||
            memory_line[6 * 8 +: 8] != 8'h66)
            $fatal(1, "masked byte write damaged an adjacent lane");

        core_issue(0, 21'h12345, 8'h00);
        wait_for_completion();
        if (core_read_data != 8'ha5)
            $fatal(1, "read-back returned %02x", core_read_data);

        $display("CPU_MEMORY_PATH_PASS");
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
                    "-o", str(simulation_path),
                    *[str(path) for path in MEMORY_RTL],
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
            self.assertIn("CPU_MEMORY_PATH_PASS", simulation_result.stdout)


if __name__ == "__main__":
    unittest.main()
