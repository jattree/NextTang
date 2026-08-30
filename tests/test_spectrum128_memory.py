"""Behavioural checks for the first banked 128K DDR3 memory boundary."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = (
    REPO_ROOT / "rtl/memory/nexttang_block_ram.v",
    REPO_ROOT / "rtl/memory/nexttang_cpu_memory_service.v",
    REPO_ROOT / "rtl/memory/nexttang_memory_cdc_bridge.v",
    REPO_ROOT / "rtl/memory/nexttang_byte_line_adapter.v",
    REPO_ROOT / "rtl/memory/nexttang_cpu_memory_path.v",
    REPO_ROOT / "rtl/memory/nexttang_spectrum128_memory.v",
)


class Spectrum128MemoryTests(unittest.TestCase):
    def test_screen_banks_are_cpu_visible_and_video_selectable(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg cpu_clock = 0, video_clock = 0, memory_clock = 0;
    reg cpu_reset = 1, memory_reset = 1, memory_available = 0;
    reg [15:0] cpu_address = 0;
    reg [2:0] cpu_bank = 0;
    reg [7:0] cpu_write_data = 0;
    reg cpu_mreq_n = 1, cpu_rd_n = 1, cpu_wr_n = 1, cpu_rfsh_n = 1;
    reg video_bank = 0;
    reg [13:0] video_address = 0;
    wire [7:0] ram_read_data, video_data;
    wire cpu_wait_n, transaction_complete;
    wire line_request, line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    wire fault_timeout, fault_overrun, fault_calibration_lost;

    always #5 cpu_clock = ~cpu_clock;
    always #7 video_clock = ~video_clock;
    always #3 memory_clock = ~memory_clock;

    nexttang_spectrum128_memory dut (
        .cpu_clock(cpu_clock), .cpu_reset(cpu_reset),
        .memory_available(memory_available), .cpu_address(cpu_address),
        .cpu_bank(cpu_bank), .cpu_write_data(cpu_write_data),
        .cpu_mreq_n(cpu_mreq_n), .cpu_rd_n(cpu_rd_n),
        .cpu_wr_n(cpu_wr_n), .cpu_rfsh_n(cpu_rfsh_n),
        .ram_read_data(ram_read_data), .cpu_wait_n(cpu_wait_n),
        .transaction_complete(transaction_complete),
        .video_clock(video_clock), .video_bank(video_bank),
        .video_address(video_address), .video_data(video_data),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .line_request(line_request), .line_ready(1'b0),
        .line_write(line_write), .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(1'b0), .line_read_data(128'b0),
        .fault_timeout(fault_timeout), .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

    task write_local(input [2:0] bank, input [13:0] address, input [7:0] value);
        begin
            @(negedge cpu_clock);
            cpu_bank = bank; cpu_address = {2'b01, address};
            cpu_write_data = value; cpu_mreq_n = 0; cpu_wr_n = 0;
            @(posedge cpu_clock); @(negedge cpu_clock);
            cpu_mreq_n = 1; cpu_wr_n = 1;
        end
    endtask

    task read_local(input [2:0] bank, input [13:0] address, input [7:0] want);
        begin
            @(negedge cpu_clock);
            cpu_bank = bank; cpu_address = {2'b01, address};
            cpu_mreq_n = 0; cpu_rd_n = 0;
            @(posedge cpu_clock); #1;
            if (ram_read_data !== want)
                $fatal(1, "bank %0d read %02x, expected %02x", bank,
                       ram_read_data, want);
            if (!cpu_wait_n) $fatal(1, "local screen RAM must never wait");
            @(negedge cpu_clock); cpu_mreq_n = 1; cpu_rd_n = 1;
        end
    endtask

    task read_video(input bank, input [13:0] address, input [7:0] want);
        begin
            @(negedge video_clock); video_bank = bank; video_address = address;
            @(posedge video_clock); #1;
            if (video_data !== want)
                $fatal(1, "video bank %0d read %02x, expected %02x", bank,
                       video_data, want);
        end
    endtask

    initial begin
        repeat (2) @(posedge cpu_clock);
        cpu_reset = 0; memory_reset = 0;
        write_local(3'd5, 14'h0123, 8'h55);
        write_local(3'd7, 14'h0123, 8'h77);
        read_local(3'd5, 14'h0123, 8'h55);
        read_local(3'd7, 14'h0123, 8'h77);
        read_video(1'b0, 14'h0123, 8'h55);
        read_video(1'b1, 14'h0123, 8'h77);
        $display("SPECTRUM128_SCREEN_BANKS_PASS");
        $finish;
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "testbench.v"
            output = root / "testbench.vvp"
            source.write_text(testbench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), *(str(path) for path in RTL), str(source)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run(
                ["vvp", str(output)], cwd=REPO_ROOT,
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("SPECTRUM128_SCREEN_BANKS_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
