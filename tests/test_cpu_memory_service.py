"""Behavioural tests for the stallable machine-core CPU memory service."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
MEMORY_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_cpu_memory_service.v"


class CpuMemoryServiceTest(unittest.TestCase):
    def run_iverilog(self, testbench: str) -> str:
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
                    str(MEMORY_RTL),
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
            self.assertEqual(simulation_result.returncode, 0, simulation_result.stdout)
            return simulation_result.stdout

    def test_backpressure_response_binding_and_faults(self) -> None:
        output = self.run_iverilog(
            r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg calibrated = 0;
    reg core_request = 0;
    reg core_read_n = 0;
    reg [20:0] core_address = 0;
    reg [7:0] core_write_data = 0;
    wire [7:0] core_read_data;
    wire core_wait;
    wire core_complete;
    wire memory_request;
    reg memory_ready = 0;
    wire memory_write;
    wire [20:0] memory_address;
    wire [7:0] memory_write_data;
    reg memory_response_valid = 0;
    reg [7:0] memory_read_data = 0;
    wire fault_timeout;
    wire fault_overrun;
    wire fault_calibration_lost;

    always #5 clock = ~clock;

    nexttang_cpu_memory_service #(.MAX_WAIT_CYCLES(8)) dut (
        .clock(clock), .reset(reset), .calibrated(calibrated),
        .core_request(core_request), .core_read_n(core_read_n),
        .core_address(core_address), .core_write_data(core_write_data),
        .core_read_data(core_read_data), .core_wait(core_wait),
        .core_complete(core_complete), .memory_request(memory_request),
        .memory_ready(memory_ready), .memory_write(memory_write),
        .memory_address(memory_address), .memory_write_data(memory_write_data),
        .memory_response_valid(memory_response_valid),
        .memory_read_data(memory_read_data), .fault_timeout(fault_timeout),
        .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

    task pulse_request;
        input read_n;
        input [20:0] address;
        input [7:0] write_data;
        begin
            @(negedge clock);
            core_read_n = read_n;
            core_address = address;
            core_write_data = write_data;
            core_request = 1;
            @(negedge clock);
            core_request = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clock);
        #1;
        if (!core_wait)
            $fatal(1, "CPU was released before memory calibration");

        reset = 0;
        calibrated = 1;
        @(posedge clock);
        #1;
        if (core_wait)
            $fatal(1, "CPU remained stalled after calibration");

        pulse_request(0, 21'h12345, 8'h00);
        #1;
        if (!core_wait || !memory_request || memory_write)
            $fatal(1, "read request was not issued and stalled");
        if (memory_address != 21'h12345)
            $fatal(1, "read address was not captured");

        core_address = 21'h05555;
        core_write_data = 8'hcc;
        repeat (3) begin
            @(posedge clock);
            #1;
            if (memory_address != 21'h12345 || !memory_request)
                $fatal(1, "request metadata changed under backpressure");
        end

        @(negedge clock);
        memory_ready = 1;
        @(posedge clock);
        #1;
        memory_ready = 0;
        if (memory_request || !core_wait)
            $fatal(1, "accepted read did not wait for its response");

        repeat (2) @(posedge clock);
        @(negedge clock);
        memory_read_data = 8'ha7;
        memory_response_valid = 1;
        @(posedge clock);
        #1;
        memory_response_valid = 0;
        if (!core_complete || core_wait || core_read_data != 8'ha7)
            $fatal(1, "read response was not bound to the request");

        @(posedge clock);
        #1;
        if (core_complete)
            $fatal(1, "completion was not a one-cycle pulse");

        pulse_request(1, 21'h1a2b3, 8'h5c);
        #1;
        if (!memory_request || !memory_write ||
            memory_address != 21'h1a2b3 || memory_write_data != 8'h5c)
            $fatal(1, "write request metadata was not captured");

        @(negedge clock);
        memory_ready = 1;
        memory_response_valid = 1;
        @(posedge clock);
        #1;
        memory_ready = 0;
        memory_response_valid = 0;
        if (!core_complete || core_wait)
            $fatal(1, "same-cycle write acknowledgement did not complete");

        pulse_request(0, 21'h00010, 8'h00);
        repeat (2) @(posedge clock);
        pulse_request(0, 21'h00020, 8'h00);
        #1;
        if (!fault_overrun)
            $fatal(1, "second request while busy was not detected");

        @(negedge clock);
        memory_ready = 1;
        @(posedge clock);
        #1;
        memory_ready = 0;
        @(negedge clock);
        memory_response_valid = 1;
        memory_read_data = 8'h11;
        @(posedge clock);
        #1;
        memory_response_valid = 0;
        if (core_wait || core_read_data != 8'h11)
            $fatal(1, "original request did not survive overrun detection");

        pulse_request(0, 21'h00030, 8'h00);
        @(negedge clock);
        memory_ready = 1;
        @(posedge clock);
        #1;
        memory_ready = 0;
        calibrated = 0;
        @(posedge clock);
        #1;
        if (!fault_calibration_lost || !core_wait)
            $fatal(1, "calibration loss did not enter a visible fault state");

        reset = 1;
        repeat (2) @(posedge clock);
        reset = 0;
        calibrated = 1;
        @(posedge clock);
        #1;
        if (fault_overrun || fault_calibration_lost || core_wait)
            $fatal(1, "reset did not clear service faults");

        pulse_request(0, 21'h00040, 8'h00);
        repeat (9) @(posedge clock);
        #1;
        if (!fault_timeout || !core_wait || memory_request)
            $fatal(1, "bounded wait timeout did not fail closed");

        #2;
        reset = 1;
        #1;
        if (fault_timeout || fault_overrun || fault_calibration_lost ||
            memory_request)
            $fatal(1, "asynchronous reset did not clear service state");

        $display("CPU_MEMORY_SERVICE_PASS");
        $finish;
    end
endmodule
"""
        )
        self.assertIn("CPU_MEMORY_SERVICE_PASS", output)


if __name__ == "__main__":
    unittest.main()
