"""Regression tests for the first Spectrum 48K DDR3 memory split."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class Spectrum48SplitMemoryTests(unittest.TestCase):
    def test_lower_ram_stays_local_and_upper_ram_crosses_line_service(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg cpu_clock = 0;
    reg memory_clock = 0;
    reg cpu_reset = 1;
    reg memory_reset = 1;
    reg memory_available = 0;
    reg [15:0] cpu_address = 0;
    reg [7:0] cpu_write_data = 0;
    reg cpu_mreq_n = 1;
    reg cpu_rd_n = 1;
    reg cpu_wr_n = 1;
    reg cpu_rfsh_n = 1;
    wire [7:0] ram_read_data;
    wire cpu_wait_n;
    wire upper_transaction_complete;

    reg [13:0] video_address = 0;
    wire [7:0] video_data;

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

    reg [127:0] lines [0:4095];
    reg pending = 0;
    reg pending_write = 0;
    reg [11:0] pending_address = 0;
    reg [127:0] pending_write_data = 0;
    reg [15:0] pending_write_enable = 0;
    integer delay = 0;
    integer lane;

    always #5 cpu_clock = ~cpu_clock;
    always #3 memory_clock = ~memory_clock;

    nexttang_spectrum48_split_memory dut (
        .cpu_clock(cpu_clock), .cpu_reset(cpu_reset),
        .memory_available(memory_available),
        .cpu_address(cpu_address), .cpu_write_data(cpu_write_data),
        .cpu_mreq_n(cpu_mreq_n), .cpu_rd_n(cpu_rd_n),
        .cpu_wr_n(cpu_wr_n), .cpu_rfsh_n(cpu_rfsh_n),
        .ram_read_data(ram_read_data), .cpu_wait_n(cpu_wait_n),
        .upper_transaction_complete(upper_transaction_complete),
        .video_clock(memory_clock), .video_address(video_address),
        .video_data(video_data),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .line_request(line_request), .line_ready(line_ready),
        .line_write(line_write), .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .fault_timeout(fault_timeout), .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

    always @(posedge memory_clock) begin
        line_response_valid <= 0;
        if (!pending && line_request && line_ready) begin
            pending <= 1;
            pending_write <= line_write;
            pending_address <= line_address[11:0];
            pending_write_data <= line_write_data;
            pending_write_enable <= line_write_enable;
            delay <= 3;
        end else if (pending && delay > 1) begin
            delay <= delay - 1;
        end else if (pending) begin
            if (pending_write) begin
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (pending_write_enable[lane])
                        lines[pending_address][lane*8 +: 8] <=
                            pending_write_data[lane*8 +: 8];
            end else begin
                line_read_data <= lines[pending_address];
            end
            line_response_valid <= 1;
            pending <= 0;
        end
    end

    task lower_write;
        input [15:0] address;
        input [7:0] value;
        begin
            @(negedge cpu_clock);
            cpu_address <= address;
            cpu_write_data <= value;
            cpu_mreq_n <= 0;
            cpu_wr_n <= 0;
            @(negedge cpu_clock);
            if (!cpu_wait_n)
                $fatal(1, "lower RAM write was stalled");
            cpu_mreq_n <= 1;
            cpu_wr_n <= 1;
        end
    endtask

    task lower_read;
        input [15:0] address;
        input [7:0] expected;
        begin
            @(negedge cpu_clock);
            cpu_address <= address;
            cpu_mreq_n <= 0;
            cpu_rd_n <= 0;
            @(negedge cpu_clock);
            if (!cpu_wait_n)
                $fatal(1, "lower RAM read was stalled");
            if (ram_read_data !== expected)
                $fatal(1, "lower RAM read %02x expected %02x",
                       ram_read_data, expected);
            cpu_mreq_n <= 1;
            cpu_rd_n <= 1;
        end
    endtask

    task upper_write;
        input [15:0] address;
        input [7:0] value;
        integer wait_cycles;
        begin
            @(negedge cpu_clock);
            cpu_address <= address;
            cpu_write_data <= value;
            cpu_mreq_n <= 0;
            cpu_wr_n <= 0;
            #1;
            if (cpu_wait_n)
                $fatal(1, "upper RAM write did not assert WAIT immediately");
            @(negedge cpu_clock);
            wait_cycles = 0;
            while (!upper_transaction_complete && wait_cycles < 100) begin
                if (cpu_wait_n)
                    $fatal(1, "upper RAM write released WAIT early");
                @(negedge cpu_clock);
                wait_cycles = wait_cycles + 1;
            end
            if (!upper_transaction_complete)
                $fatal(1, "upper RAM write timed out");
            if (!cpu_wait_n)
                $fatal(1, "upper RAM write did not release WAIT");
            cpu_mreq_n <= 1;
            cpu_wr_n <= 1;
        end
    endtask

    task upper_read;
        input [15:0] address;
        input [7:0] expected;
        integer wait_cycles;
        begin
            @(negedge cpu_clock);
            cpu_address <= address;
            cpu_mreq_n <= 0;
            cpu_rd_n <= 0;
            #1;
            if (cpu_wait_n)
                $fatal(1, "upper RAM read did not assert WAIT immediately");
            @(negedge cpu_clock);
            wait_cycles = 0;
            while (!upper_transaction_complete && wait_cycles < 100) begin
                if (cpu_wait_n)
                    $fatal(1, "upper RAM read released WAIT early");
                @(negedge cpu_clock);
                wait_cycles = wait_cycles + 1;
            end
            if (!upper_transaction_complete)
                $fatal(1, "upper RAM read timed out");
            if (ram_read_data !== expected)
                $fatal(1, "upper RAM read %02x expected %02x",
                       ram_read_data, expected);
            cpu_mreq_n <= 1;
            cpu_rd_n <= 1;
        end
    endtask

    initial begin
        repeat (4) @(posedge cpu_clock);
        cpu_reset <= 0;
        memory_reset <= 0;
        memory_available <= 1;

        lower_write(16'h4001, 8'h5a);
        lower_read(16'h4001, 8'h5a);
        video_address <= 14'h0001;
        repeat (2) @(posedge memory_clock);
        if (video_data !== 8'h5a)
            $fatal(1, "ULA port did not see lower RAM write");
        if (line_request)
            $fatal(1, "lower RAM touched the external line service");

        upper_write(16'h8003, 8'ha5);
        upper_read(16'h8003, 8'ha5);
        upper_write(16'hffff, 8'h3c);
        upper_read(16'hffff, 8'h3c);

        if (fault_timeout || fault_overrun || fault_calibration_lost)
            $fatal(1, "unexpected memory fault");

        $display("SPECTRUM48_SPLIT_MEMORY_PASS");
        $finish;
    end
endmodule
"""
        sources = [
            "rtl/memory/nexttang_block_ram.v",
            "rtl/memory/nexttang_cpu_memory_service.v",
            "rtl/memory/nexttang_memory_cdc_bridge.v",
            "rtl/memory/nexttang_byte_line_adapter.v",
            "rtl/memory/nexttang_cpu_memory_path.v",
            "rtl/memory/nexttang_spectrum48_split_memory.v",
        ]

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
                    *(str(REPO_ROOT / source) for source in sources),
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
                simulation_result.returncode,
                0,
                simulation_result.stdout + simulation_result.stderr,
            )
            self.assertIn("SPECTRUM48_SPLIT_MEMORY_PASS", simulation_result.stdout)


if __name__ == "__main__":
    unittest.main()
