"""Behavioural test for the ZXNext main-memory port adapter.

The core holds o_RAM_A_REQ2 high for a whole memory cycle and samples the
active-high wait input only at the CPU's own clock edges, which at 3.5 MHz come
once every eight 28 MHz cycles. The adapter must assert wait from the request
at once, release it on completion, and keep it released until the request ends.
"""

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
    REPO_ROOT / "rtl" / "memory" / "nexttang_zxnext_memory_port.v",
]

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg machine_clock = 0;
    reg machine_reset = 1;
    reg memory_available = 0;
    reg core_request = 0;
    reg core_read_n = 1;
    reg [20:0] core_address = 0;
    reg [7:0] core_write_data = 0;
    wire [7:0] core_read_data;
    wire core_wait;

    reg memory_clock = 0;
    reg memory_reset = 1;
    wire line_request;
    reg line_ready = 1;
    wire line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    reg line_response_valid = 0;
    reg [127:0] line_read_data = 0;
    wire fault_timeout;
    wire fault_overrun;
    wire fault_calibration_lost;

    reg [127:0] lines [0:255];
    reg pending = 0;
    reg [7:0] pending_line = 0;
    reg [3:0] delay = 0;
    integer lane;
    integer i;

    always #17.857 machine_clock = !machine_clock;   // 28 MHz
    always #5 memory_clock = !memory_clock;           // 100 MHz controller

    nexttang_zxnext_memory_port dut (
        .machine_clock(machine_clock), .machine_reset(machine_reset),
        .memory_available(memory_available),
        .core_request(core_request), .core_read_n(core_read_n),
        .core_address(core_address), .core_write_data(core_write_data),
        .core_read_data(core_read_data), .core_wait(core_wait),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .line_request(line_request), .line_ready(line_ready),
        .line_write(line_write), .line_address(line_address),
        .line_write_data(line_write_data), .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid), .line_read_data(line_read_data),
        .fault_timeout(fault_timeout), .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

    // A line memory with a DDR3-like delay of several controller cycles.
    always @(posedge memory_clock) begin
        line_response_valid <= 1'b0;
        if (line_request && line_ready) begin
            if (line_write)
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (line_write_enable[lane])
                        lines[line_address[7:0]][lane * 8 +: 8]
                            <= line_write_data[lane * 8 +: 8];
            pending <= 1'b1;
            pending_line <= line_address[7:0];
            delay <= 9;
        end else if (pending && delay != 0) begin
            delay <= delay - 1'b1;
        end else if (pending) begin
            line_read_data <= lines[pending_line];
            line_response_valid <= 1'b1;
            pending <= 1'b0;
        end
    end

    // One CPU memory cycle as the core presents it. The request is held high
    // and wait is examined only every eighth machine cycle, as a 3.5 MHz CPU
    // would. The cycle ends a further eight cycles after wait is seen low,
    // so wait must stay low across that whole gap.
    task cpu_cycle;
        input read_n;
        input [20:0] address;
        input [7:0] write_data;
        output [7:0] read_data;
        integer samples;
        integer gap;
        begin
            @(negedge machine_clock);
            core_read_n = read_n;
            core_address = address;
            core_write_data = write_data;
            core_request = 1;
            #1;
            if (!core_wait)
                $fatal(1, "wait was not asserted with the request");
            samples = 0;
            while (core_wait && samples < 200) begin
                repeat (8) @(negedge machine_clock);
                samples = samples + 1;
            end
            if (core_wait)
                $fatal(1, "wait never released");
            read_data = core_read_data;
            for (gap = 0; gap < 8; gap = gap + 1) begin
                @(negedge machine_clock);
                if (core_wait)
                    $fatal(1, "wait rose again before the cycle ended");
            end
            core_request = 0;
            @(negedge machine_clock);
            if (fault_timeout || fault_overrun || fault_calibration_lost)
                $fatal(1, "memory path raised a fault");
        end
    endtask

    reg [7:0] value;

    initial begin
        for (i = 0; i < 256; i = i + 1)
            lines[i] = 128'b0;
        repeat (4) @(posedge machine_clock);
        if (!core_wait)
            $fatal(1, "wait must hold the CPU until memory is available");
        machine_reset = 0;
        memory_reset = 0;
        memory_available = 1;
        repeat (4) @(posedge machine_clock);

        cpu_cycle(1'b1, 21'h048123, 8'h5a, value);
        cpu_cycle(1'b1, 21'h1fffff, 8'ha5, value);
        cpu_cycle(1'b0, 21'h048123, 8'h00, value);
        if (value !== 8'h5a)
            $fatal(1, "read back %02x from 048123, expected 5a", value);
        cpu_cycle(1'b0, 21'h1fffff, 8'h00, value);
        if (value !== 8'ha5)
            $fatal(1, "read back %02x from 1fffff, expected a5", value);

        $display("ZXNEXT_MEMORY_PORT_PASS");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "testbench timed out");
    end
endmodule
"""


class ZxnextMemoryPortTest(unittest.TestCase):
    def test_wait_follows_request_and_survives_slow_sampling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.v"
            testbench_path.write_text(TESTBENCH, encoding="utf-8")
            simulation_path = temporary_path / "simulation.vvp"
            for command in (
                [
                    "iverilog", "-g2012", "-Wall", "-s", "testbench",
                    "-o", str(simulation_path),
                    *map(str, MEMORY_RTL), str(testbench_path),
                ],
                ["vvp", str(simulation_path)],
            ):
                result = subprocess.run(
                    command,
                    cwd=temporary_path,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ZXNEXT_MEMORY_PORT_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
