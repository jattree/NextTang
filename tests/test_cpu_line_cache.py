"""The CPU line cache must never return stale data and must answer hits fast.

rtl/memory/nexttang_cpu_line_cache.v sits in nexttang_zxnext_memory_port when
CACHE is set. The test drives the port as the core does, with random reads and
writes over lines chosen so that several share each cache index, against a
DDR3-like line memory with a delay. Some reads are withdrawn before they are
answered, as the core can do when divMMC paging changes under an access; the
next access must still be served, promptly and with the right data. Every read is checked against a reference
copy of memory. It runs once with wait examined every cycle, as a 28 MHz CPU
does, and once every eighth cycle, as at 3.5 MHz, and checks that a read the
cache can answer waits exactly two cycles.
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
    REPO_ROOT / "rtl" / "memory" / "nexttang_cpu_line_cache.v",
    REPO_ROOT / "rtl" / "memory" / "nexttang_zxnext_memory_port.v",
]

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    localparam integer SAMPLE_EVERY = %(sample_every)d;
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
    wire fault_timeout, fault_overrun, fault_calibration_lost;

    reg [127:0] lines [0:131071];
    reg [7:0] reference [0:2097151];
    reg pending = 0;
    reg [16:0] pending_line = 0;
    reg [3:0] delay = 0;
    integer lane, i;

    always #17.857 machine_clock = !machine_clock;   // 28 MHz
    always #5 memory_clock = !memory_clock;           // 100 MHz controller

    nexttang_zxnext_memory_port #(.CACHE(1)) dut (
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

    always @(posedge memory_clock) begin
        line_response_valid <= 1'b0;
        if (line_request && line_ready) begin
            if (line_write)
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (line_write_enable[lane])
                        lines[line_address][lane * 8 +: 8]
                            <= line_write_data[lane * 8 +: 8];
            pending <= 1'b1;
            pending_line <= line_address;
            delay <= 4 + ($urandom %% 10);
        end else if (pending && delay != 0) begin
            delay <= delay - 1'b1;
        end else if (pending) begin
            line_read_data <= lines[pending_line];
            line_response_valid <= 1'b1;
            pending <= 1'b0;
        end
    end

    integer waited;
    task cpu_cycle;
        input read_n;
        input [20:0] address;
        input [7:0] write_data;
        output [7:0] read_data;
        integer hold;
        begin
            @(negedge machine_clock);
            core_read_n = read_n;
            core_address = address;
            core_write_data = write_data;
            core_request = 1;
            #1;
            if (!core_wait)
                $fatal(1, "wait was not asserted with the request");
            waited = 0;
            while (core_wait && waited < 4000) begin
                repeat (SAMPLE_EVERY) @(negedge machine_clock);
                waited = waited + SAMPLE_EVERY;
            end
            if (core_wait)
                $fatal(1, "wait never released");
            read_data = core_read_data;
            for (hold = $urandom %% (2 * SAMPLE_EVERY); hold > 0; hold = hold - 1) begin
                @(negedge machine_clock);
                if (core_wait)
                    $fatal(1, "wait rose again before the cycle ended");
            end
            if (core_read_data !== read_data)
                $fatal(1, "read data changed before the cycle ended");
            core_request = 0;
            core_address = 21'hxxxxxx;
            repeat ($urandom %% 3) @(negedge machine_clock);
            if (fault_timeout || fault_overrun || fault_calibration_lost)
                $fatal(1, "memory path raised a fault");
        end
    endtask

    // A read the core withdraws before it is answered, as divMMC paging can
    // make it do: the request drops after a few cycles whatever wait says.
    task withdrawn_read;
        input [20:0] address;
        integer hold;
        begin
            @(negedge machine_clock);
            core_read_n = 1'b0;
            core_address = address;
            core_request = 1;
            for (hold = $urandom %% 13; hold > 0; hold = hold - 1)
                @(negedge machine_clock);
            core_request = 0;
            core_address = 21'hxxxxxx;
            repeat ($urandom %% 3) @(negedge machine_clock);
        end
    endtask

    // Eight cache indices, four lines on each: addresses 16 KiB apart share
    // an index.
    function [20:0] random_address;
        input integer unused;
        begin
            random_address = (($urandom %% 4) * 21'h4000 + ($urandom %% 2) * 21'h100000) |
                             (($urandom %% 8) << 4) | ($urandom %% 16);
        end
    endfunction

    reg [7:0] value;
    reg [20:0] address;
    integer step, reads = 0, fast_hits = 0, slowest = 0;
    reg was_read;

    initial begin
        for (i = 0; i < 131072; i = i + 1)
            lines[i] = 128'b0;
        for (i = 0; i < 2097152; i = i + 1)
            reference[i] = 8'h00;
        repeat (4) @(posedge machine_clock);
        machine_reset = 0;
        memory_reset = 0;
        memory_available = 1;
        repeat (4) @(posedge machine_clock);

        for (step = 0; step < 4000; step = step + 1) begin
            if ($urandom %% 6 == 0)
                withdrawn_read(random_address(0));
            address = random_address(0);
            was_read = 1'b0;
            if ($urandom %% 3 == 0) begin
                value = $urandom;
                reference[address] = value;
                cpu_cycle(1'b1, address, value, value);
            end else begin
                cpu_cycle(1'b0, address, 8'h00, value);
                was_read = 1'b1;
                reads = reads + 1;
                if (value !== reference[address])
                    $fatal(1, "step %%0d: read %%02x from %%06x, expected %%02x",
                           step, value, address, reference[address]);
                if (waited == 2) fast_hits = fast_hits + 1;
                if (waited > slowest) slowest = waited;
            end
            // Read the same byte straight back. After a read it must hit; a
            // write that missed does not fetch its line, so after one it
            // need not.
            if ($urandom %% 4 == 0) begin
                cpu_cycle(1'b0, address, 8'h00, value);
                if (value !== reference[address])
                    $fatal(1, "step %%0d: reread %%02x from %%06x, expected %%02x",
                           step, value, address, reference[address]);
                if (SAMPLE_EVERY == 1 && was_read && waited != 2)
                    $fatal(1, "step %%0d: a reread waited %%0d cycles", step, waited);
            end
        end
        $display("READS %%0d FAST %%0d SLOWEST %%0d", reads, fast_hits, slowest);
        $display("LINE_CACHE_PASS");
        $finish;
    end
endmodule
"""


def run(sample_every: int) -> str:
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_path = Path(temporary_directory)
        testbench_path = temporary_path / "testbench.v"
        testbench_path.write_text(TESTBENCH % {"sample_every": sample_every}, encoding="utf-8")
        simulation_path = temporary_path / "simulation.vvp"
        for command in (
            ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o", str(simulation_path),
             *map(str, MEMORY_RTL), str(testbench_path)],
            ["vvp", str(simulation_path)],
        ):
            result = subprocess.run(command, cwd=temporary_path, check=False,
                                    capture_output=True, text=True, timeout=600)
            if result.returncode != 0:
                raise AssertionError(result.stdout + result.stderr)
        return result.stdout


class CpuLineCacheTest(unittest.TestCase):
    def test_every_cycle_sampling_like_28mhz(self) -> None:
        output = run(1)
        self.assertIn("LINE_CACHE_PASS", output)
        reads, fast, slowest = (int(v) for v in output.split("READS ")[1].split()[0:5:2])
        # 32 lines on 8 indices: most reads miss, but many hit.
        self.assertGreater(fast, reads // 10)
        self.assertGreater(slowest, 2)

    def test_every_eighth_cycle_sampling_like_3_5mhz(self) -> None:
        self.assertIn("LINE_CACHE_PASS", run(8))


if __name__ == "__main__":
    unittest.main()
