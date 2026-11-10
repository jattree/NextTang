"""Port C (the Pi debug slave's) must share main memory with port A safely.

rtl/memory/nexttang_zxnext_port_c_mux.v puts the official core's port C on
the same path as port A, ahead of the cache. Downstream here is a model of
nexttang_zxnext_memory_port: wait follows a request until it is answered a few
cycles later and stays low until the request drops. The test checks that port
C reads and writes land, that a CPU access arriving meanwhile waits and then
sees the debugger's write, that each port C request is served exactly once,
and that port A is never starved by port C.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (REPO_ROOT / "rtl" / "memory" / "nexttang_zxnext_port_c_mux.v",)

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    always #17.857 clock = !clock;

    reg a_request = 0, a_read_n = 0;
    reg [20:0] a_address = 0;
    reg [7:0] a_write_data = 0;
    wire a_wait;
    reg c_request = 0, c_read_n = 0;
    reg [20:0] c_address = 0;
    reg [7:0] c_write_data = 0;
    wire c_ack, c_busy;
    wire [7:0] c_read_data;
    wire down_request, down_read_n;
    wire [20:0] down_address;
    wire [7:0] down_write_data;
    reg [7:0] down_read_data = 0;
    reg done = 0;
    integer count = 0;
    integer accesses = 0;
    reg [7:0] memory [0:255];

    nexttang_zxnext_port_c_mux dut (
        .clock(clock), .reset(reset),
        .a_request(a_request), .a_read_n(a_read_n), .a_address(a_address),
        .a_write_data(a_write_data), .a_wait(a_wait),
        .c_request(c_request), .c_read_n(c_read_n), .c_address(c_address),
        .c_write_data(c_write_data), .c_ack(c_ack), .c_read_data(c_read_data),
        .down_request(down_request), .down_read_n(down_read_n),
        .down_address(down_address), .down_write_data(down_write_data),
        .down_wait(down_request && !done), .down_read_data(down_read_data),
        .c_busy(c_busy)
    );

    // The memory port: answers WAIT cycles after a request rises, keeps the
    // answer until the request drops.
    localparam integer WAIT = 6;
    always @(posedge clock) begin
        if (!down_request) begin
            done <= 0;
            count <= 0;
        end else if (!done) begin
            if (count == 0)
                accesses <= accesses + 1;
            count <= count + 1;
            if (count == WAIT) begin
                done <= 1;
                if (down_read_n)
                    memory[down_address[7:0]] <= down_write_data;
                else
                    down_read_data <= memory[down_address[7:0]];
            end
        end
    end

    // The official slave: request held until the acknowledge, dropped on
    // the next cycle; read data taken the cycle after the acknowledge.
    task automatic port_c(input [7:0] address, input [7:0] data, input is_write, output [7:0] result);
        integer guard;
        begin
            @(negedge clock);
            c_address = address;
            c_read_n = is_write;
            c_write_data = data;
            c_request = 1;
            guard = 0;
            @(posedge clock);
            while (!c_ack) begin
                guard = guard + 1;
                if (guard > 200) $fatal(1, "port C never acknowledged");
                @(posedge clock);
            end
            @(negedge clock);
            c_request = 0;
            @(posedge clock);
            result = c_read_data;
        end
    endtask

    // The core's port A: request held until wait falls, then dropped.
    task automatic port_a(input [7:0] address, input [7:0] data, input is_write, output [7:0] result);
        integer guard;
        begin
            @(negedge clock);
            a_address = address;
            a_read_n = is_write;
            a_write_data = data;
            a_request = 1;
            guard = 0;
            @(negedge clock);
            while (a_wait) begin
                guard = guard + 1;
                if (guard > 200) $fatal(1, "port A never released");
                @(negedge clock);
            end
            result = down_read_data;
            a_request = 0;
        end
    endtask

    reg [7:0] got;
    integer start_count;
    initial begin
        repeat (4) @(posedge clock);
        reset = 0;

        port_c(8'h10, 8'hA5, 1, got);
        port_c(8'h10, 8'h00, 0, got);
        if (got !== 8'hA5) $fatal(1, "port C read back %h", got);

        // Port A sees port C's write.
        port_a(8'h10, 8'h00, 0, got);
        if (got !== 8'hA5) $fatal(1, "port A read %h after port C's write", got);

        // Port C served exactly once per request.
        start_count = accesses;
        port_c(8'h11, 8'h3C, 1, got);
        repeat (20) @(posedge clock);
        if (accesses != start_count + 1) $fatal(1, "port C write made %0d accesses", accesses - start_count);

        // Port A arrives while port C holds the path: it waits, then is served
        // with its own data, after port C's write.
        fork
            port_c(8'h20, 8'h77, 1, got);
            begin
                repeat (3) @(negedge clock);
                port_a(8'h20, 8'h00, 0, got);
                if (got !== 8'h77) $fatal(1, "port A read %h, wanted port C's 77", got);
            end
        join

        // Port A busy back to back: port C waits for a gap and is then served.
        fork
            begin
                port_a(8'h30, 8'h01, 1, got);
                port_a(8'h31, 8'h02, 1, got);
                port_a(8'h32, 8'h03, 1, got);
            end
            begin
                @(negedge clock);
                port_c(8'h31, 8'h00, 0, got);
            end
        join
        if (memory[8'h30] !== 8'h01 || memory[8'h32] !== 8'h03)
            $fatal(1, "port A writes lost");

        $display("PASS");
        $finish;
    end
endmodule
"""


class ZxnextPortCMuxTest(unittest.TestCase):
    def test_port_c_shares_main_memory(self) -> None:
        output = run_testbench(TESTBENCH, *SOURCES)
        self.assertIn("PASS", output)


if __name__ == "__main__":
    unittest.main()
