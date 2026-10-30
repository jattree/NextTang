"""The Layer 2 mirror must copy main-memory writes in its range and serve them.

rtl/video/nexttang_layer2_mirror.v stands in for the SRAM port Layer 2 reads,
which DDR3 is too slow to serve. The test writes through the snooped port A
inside and outside the mirrored banks and reads back through the Layer 2 port
with the core's timing: address registered, data sampled four cycles later.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    REPO_ROOT / "rtl" / "memory" / "nexttang_block_ram.v",
    REPO_ROOT / "rtl" / "video" / "nexttang_layer2_mirror.v",
)

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock_28 = 0;
    reg write_request = 0;
    reg write_n_read = 0;
    reg [20:0] write_address = 0;
    reg [7:0] write_data = 0;
    reg [20:0] read_address = 0;
    wire [7:0] read_data;
    reg spec256_mode = 0;
    reg [15:0] lane_address = 0, overlay_address = 0;
    reg lane_write = 0;
    reg [63:0] lane_write_data = 0;
    wire [63:0] lane_read_data, overlay_data;

    nexttang_layer2_mirror dut (
        .clock_28(clock_28),
        .write_request(write_request),
        .write_n_read(write_n_read),
        .write_address(write_address),
        .write_data(write_data),
        .read_address(read_address),
        .read_data(read_data),
        .check_data(), .check_hit(),
        .spec256_mode(spec256_mode),
        .lane_address(lane_address), .lane_write(lane_write),
        .lane_write_data(lane_write_data), .lane_read_data(lane_read_data),
        .overlay_address(overlay_address), .overlay_data(overlay_data)
    );

    always #17.857 clock_28 = !clock_28;

    task automatic cpu_cycle(input [20:0] address, input [7:0] data, input is_write);
        begin
            @(negedge clock_28);
            write_address = address;
            write_n_read = is_write;
            write_data = 8'hxx;
            write_request = 1;
            @(negedge clock_28);
            write_data = data;
            repeat (3) @(negedge clock_28);
            write_request = 0;
            write_n_read = 0;
        end
    endtask

    task automatic expect_read(input [20:0] address, input [7:0] expected);
        begin
            @(negedge clock_28);
            read_address = address;
            repeat (4) @(negedge clock_28);
            if (read_data !== expected)
                $fatal(1, "read %h gave %h, expected %h", address, read_data, expected);
        end
    endtask

    initial begin
        // Range A: bank 8 starts at SRAM 0x060000, bank 12 ends at 0x073fff.
        // Range B: bank 18 starts at 0x088000, bank 22 ends at 0x09bfff.
        cpu_cycle(21'h060000, 8'h11, 1);
        cpu_cycle(21'h073fff, 8'h22, 1);
        cpu_cycle(21'h06abcd, 8'h33, 1);
        cpu_cycle(21'h088000, 8'h66, 1);
        cpu_cycle(21'h09bfff, 8'h77, 1);
        // A read cycle must not write.
        cpu_cycle(21'h06abcd, 8'h99, 0);
        // Just outside each range, at offsets that alias the ones above.
        cpu_cycle(21'h05ffff, 8'h44, 1);
        cpu_cycle(21'h074000, 8'h55, 1);
        cpu_cycle(21'h087fff, 8'h88, 1);
        cpu_cycle(21'h09c000, 8'haa, 1);

        expect_read(21'h060000, 8'h11);
        expect_read(21'h073fff, 8'h22);
        expect_read(21'h06abcd, 8'h33);
        expect_read(21'h088000, 8'h66);
        expect_read(21'h09bfff, 8'h77);
        expect_read(21'h05ffff, 8'he3);
        expect_read(21'h074000, 8'he3);
        expect_read(21'h087fff, 8'he3);
        expect_read(21'h09c000, 8'he3);
        // Bank 13 and bank 23 writes must not have landed on bank 8 or 18.
        expect_read(21'h060000, 8'h11);
        expect_read(21'h088000, 8'h66);
        $display("LAYER2_MIRROR_PASS");
        $finish;
    end
endmodule
"""


# The board's mirror: one range of 24 banks, 8 to 31 (SRAM 0x060000 to
# 0x0bffff), which needs a five-bit slot.
WIDE_TESTBENCH = (
    TESTBENCH
    .replace("nexttang_layer2_mirror dut (",
             "nexttang_layer2_mirror #(.FIRST_A(24), .BANKS_A(24), .FIRST_B(0), .BANKS_B(0)) dut (")
    .split("    initial begin\n        // Range A")[0]
    + r"""    initial begin
        cpu_cycle(21'h060000, 8'h11, 1);     // bank 8, first byte
        cpu_cycle(21'h088000, 8'h22, 1);     // bank 18
        cpu_cycle(21'h0a1234, 8'h33, 1);     // bank 24, slot 16
        cpu_cycle(21'h0bffff, 8'h44, 1);     // bank 31, last byte
        cpu_cycle(21'h05ffff, 8'h55, 1);     // bank 7
        cpu_cycle(21'h0c0000, 8'h66, 1);     // bank 32
        cpu_cycle(21'h0e1234, 8'h77, 1);     // bank 40, aliases bank 24 in 5 bits
        expect_read(21'h060000, 8'h11);
        expect_read(21'h088000, 8'h22);
        expect_read(21'h0a1234, 8'h33);
        expect_read(21'h0bffff, 8'h44);
        expect_read(21'h05ffff, 8'he3);
        expect_read(21'h0c0000, 8'he3);
        expect_read(21'h0e1234, 8'he3);
        $display("LAYER2_MIRROR_WIDE_PASS");
        $finish;
    end
endmodule
"""
)


# In spec256_mode the board's 24-bank copy is eight 48 KiB colour planes:
# a lane write at a Spectrum address puts each lane's byte in its own plane,
# the lanes and the overlay read all eight back at once, writes below 0x4000
# are dropped, and leaving the mode gives Layer 2 its byte view again.
SPEC256_TESTBENCH = (
    WIDE_TESTBENCH.split("    initial begin\n        cpu_cycle(21'h060000")[0]
    + r"""    task automatic plane_write(input [15:0] address, input [63:0] data);
        begin
            @(negedge clock_28);
            lane_address = address; lane_write_data = data; lane_write = 1;
            @(negedge clock_28);
            lane_write = 0;
        end
    endtask

    initial begin
        spec256_mode = 1;
        plane_write(16'h4000, 64'h0807060504030201);
        plane_write(16'hffff, 64'h8877665544332211);
        plane_write(16'h3fff, 64'hdeadbeefdeadbeef);
        @(negedge clock_28);
        lane_address = 16'h4000; overlay_address = 16'hffff;
        @(negedge clock_28);
        if (lane_read_data !== 64'h0807060504030201)
            $fatal(1, "lanes read %h at 4000", lane_read_data);
        if (overlay_data !== 64'h8877665544332211)
            $fatal(1, "overlay read %h at ffff", overlay_data);
        lane_address = 16'h4001;
        @(negedge clock_28);
        if (lane_read_data === 64'hdeadbeefdeadbeef)
            $fatal(1, "a write below 0x4000 landed in the planes");
        // Layer 2's view: copy byte k of word 0 is plane k at 0x4000.
        spec256_mode = 0;
        expect_read(21'h060000, 8'h01);
        expect_read(21'h060007, 8'h08);
        $display("LAYER2_MIRROR_SPEC256_PASS");
        $finish;
    end
endmodule
"""
)


class Layer2MirrorTest(unittest.TestCase):
    def test_board_mirror_holds_spec256_planes(self) -> None:
        output = run_testbench(SPEC256_TESTBENCH, *SOURCES)
        self.assertIn("LAYER2_MIRROR_SPEC256_PASS", output)

    def test_board_mirror_covers_banks_8_to_31(self) -> None:
        output = run_testbench(WIDE_TESTBENCH, *SOURCES)
        self.assertIn("LAYER2_MIRROR_WIDE_PASS", output)

    def test_mirror_copies_writes_in_range_and_serves_reads(self) -> None:
        output = run_testbench(TESTBENCH, *SOURCES)
        self.assertIn("LAYER2_MIRROR_PASS", output)


if __name__ == "__main__":
    unittest.main()
