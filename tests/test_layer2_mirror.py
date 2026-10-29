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

    nexttang_layer2_mirror dut (
        .clock_28(clock_28),
        .write_request(write_request),
        .write_n_read(write_n_read),
        .write_address(write_address),
        .write_data(write_data),
        .read_address(read_address),
        .read_data(read_data)
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


class Layer2MirrorTest(unittest.TestCase):
    def test_board_mirror_covers_banks_8_to_31(self) -> None:
        output = run_testbench(WIDE_TESTBENCH, *SOURCES)
        self.assertIn("LAYER2_MIRROR_WIDE_PASS", output)

    def test_mirror_copies_writes_in_range_and_serves_reads(self) -> None:
        output = run_testbench(TESTBENCH, *SOURCES)
        self.assertIn("LAYER2_MIRROR_PASS", output)


if __name__ == "__main__":
    unittest.main()
