"""Spec256's DDR3 plane cache must return each address's latest word, holding the CPUs until it can.

rtl/memory/nexttang_spec256_plane_cache.v is driven as the board drives it:
words written one at a time (the loader, then the lanes), reads held until
wait_request falls, as the core's WAIT holds the CPUs. Against a DDR3 model
with random readiness and latency, every read must return the last word
written to its address, whether the line was cached, never cached, written
while cached, or dropped by invalidate; nothing may be lost at the Z80's write
rate; a hit must answer within three cycles; and DDR3 must hold every word
written, each beat's other words untouched by masked writes.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (REPO_ROOT / "rtl" / "memory" / "nexttang_spec256_plane_cache.v",)

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, memory_clock = 0, reset = 1, memory_reset = 1, invalidate = 0;
    reg lookup = 0, write = 0;
    reg [16:0] address = 0, write_address = 0;
    reg [63:0] write_data = 0;
    wire [63:0] read_data;
    wire wait_request, lost;
    wire request, command_enable, write_data_enable, write_data_end, burst;
    wire [2:0] command;
    wire [28:0] controller_address;
    wire [255:0] controller_write_data;
    wire [31:0] mask;
    reg command_ready = 0, write_data_ready = 0, read_valid = 0;
    reg [255:0] read_beat = 0;
    reg [255:0] memory [0:32767];
    reg [63:0] model [0:131071];
    integer errors = 0, reads = 0, slowest_hit = 0, waited, i, j, seed = 11, latency = 0;
    reg pending = 0;
    reg [28:0] pending_address;

    nexttang_spec256_plane_cache #(.BASE_BEAT('h30000)) dut (
        .clock(clock), .reset(reset), .invalidate(invalidate),
        .lookup(lookup), .address(address), .read_data(read_data), .wait_request(wait_request),
        .write(write), .write_address(write_address), .write_data(write_data), .lost(lost),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .controller_request(request), .controller_command_ready(command_ready),
        .controller_command(command), .controller_command_enable(command_enable),
        .controller_address(controller_address), .controller_write_data_ready(write_data_ready),
        .controller_write_data(controller_write_data), .controller_write_data_enable(write_data_enable),
        .controller_write_data_end(write_data_end), .controller_write_data_mask(mask),
        .controller_read_data(read_beat), .controller_read_data_valid(read_valid),
        .controller_burst(burst));

    always #18 clock = ~clock;
    always #5 memory_clock = ~memory_clock;

    always @(posedge memory_clock) begin
        command_ready <= !pending && ($random(seed) & 3) != 0;
        write_data_ready <= $random(seed) & 1;
        read_valid <= 1'b0;
        if (command_enable && command_ready) begin
            if (controller_address[2:0] != 0 || controller_address[28:3] < 26'h30000 ||
                controller_address[28:3] >= 26'h38000)
                $fatal(1, "address %h", controller_address);
            if (command == 3'b000) begin
                if (!write_data_enable) $fatal(1, "write without data");
                for (j = 0; j < 32; j = j + 1)
                    if (!mask[j])
                        memory[controller_address[28:3] - 26'h30000][8*j +: 8] <=
                            controller_write_data[8*j +: 8];
            end else begin
                pending <= 1; pending_address <= controller_address; latency <= 6 + ($random(seed) & 31);
            end
        end
        if (pending) begin
            if (latency == 0) begin
                read_valid <= 1; read_beat <= memory[pending_address[28:3] - 26'h30000]; pending <= 0;
            end else latency <= latency - 1;
        end
    end

    function [63:0] value(input integer a, input integer round);
        value = {a[15:0] ^ round[15:0], 15'd0, a[16], round[15:0], ~a[15:0]};
    endfunction

    task put(input integer a, input [63:0] v);
        begin
            @(negedge clock); write = 1; write_address = a; write_data = v;
            @(negedge clock); write = 0;
            model[a] = v;
            repeat (100) @(negedge clock);      // about 3.5 us, a Z80 write's pace
        end
    endtask

    task get(input integer a);
        begin
            @(negedge clock); address = a; lookup = 1;
            waited = 0;
            @(negedge clock);
            while (wait_request) begin @(negedge clock); waited = waited + 1; end
            if (read_data !== model[a]) begin
                errors = errors + 1;
                $display("address %h read %h wanted %h", a, read_data, model[a]);
            end
            reads = reads + 1;
            lookup = 0;
            repeat (3) @(negedge clock);
        end
    endtask

    integer a;
    initial begin
        for (i = 0; i < 32768; i = i + 1) memory[i] = {4{64'hdeadbeefdeadbeef}};
        for (i = 0; i < 131072; i = i + 1) model[i] = 64'hdeadbeefdeadbeef;
        repeat (4) @(negedge clock); reset = 0; memory_reset = 0;
        repeat (300) @(negedge clock);
        // Load: a run of words in bank 3, and a few elsewhere.
        for (i = 0; i < 64; i = i + 1) put(17'h0c000 + i, value(17'h0c000 + i, 1));
        put(17'h1fffc, value(17'h1fffc, 1));
        put(17'h04001, value(17'h04001, 1));
        // Reads: misses, then hits on the same lines.
        for (i = 0; i < 64; i = i + 1) get(17'h0c000 + i);
        for (i = 0; i < 64; i = i + 1) get(17'h0c000 + (i * 7) % 64);
        // A hit's wait.
        get(17'h0c005); if (waited > slowest_hit) slowest_hit = waited;
        get(17'h0c006); if (waited > slowest_hit) slowest_hit = waited;
        // Writes to cached lines, then reads of them and their neighbours.
        put(17'h0c005, value(17'h0c005, 2));
        put(17'h0c006, value(17'h0c006, 2));
        get(17'h0c005); get(17'h0c006); get(17'h0c004); get(17'h0c007);
        // A line whose index another tag shares, then the first again.
        get(17'h1fffc); get(17'h04001); get(17'h0c005);
        get(17'h00400);                    // never written
        // Invalidate, then everything comes from DDR3.
        @(negedge clock); invalidate = 1; @(negedge clock); invalidate = 0;
        repeat (300) @(negedge clock);
        for (i = 0; i < 64; i = i + 1) get(17'h0c000 + i);
        get(17'h1fffc); get(17'h04001);
        // Random traffic.
        for (i = 0; i < 400; i = i + 1) begin
            a = 17'h0c000 + ($random(seed) & 17'h3ff) + (($random(seed) & 1) ? 17'h04000 : 0);
            if ($random(seed) & 1) put(a, value(a, 3 + i)); else get(a);
        end
        $display("PLANES reads %0d errors %0d lost %0d slowest_hit %0d", reads, errors, lost, slowest_hit);
        $finish;
    end
endmodule
"""


class Spec256PlaneCacheTest(unittest.TestCase):
    def test_reads_return_the_latest_word(self) -> None:
        output = run_testbench(TESTBENCH, *SOURCES)
        self.assertIn("errors 0 lost 0", output, output)
        hit = int(output.split("slowest_hit ")[1].split()[0])
        self.assertLessEqual(hit, 3, output)


if __name__ == "__main__":
    unittest.main()
