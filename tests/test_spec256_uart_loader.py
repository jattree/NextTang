"""The Spec256 UART loader must turn its commands into plane, palette and arm writes.

rtl/input/nexttang_spec256_uart_loader.v is fed bytes as the UART receiver
gives them. Raw plane and palette bytes, including ones that look like other
commands ("K", "S", "G"), must land as data while payload is high, and the
mode, arm and disarm commands must act.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (REPO_ROOT / "rtl" / "input" / "nexttang_spec256_uart_loader.v",)

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, valid = 0;
    reg [7:0] byte_in = 0;
    wire payload, mode, plane_write, palette_write, arm, disarm;
    wire [15:0] plane_address, arm_pc;
    wire [63:0] plane_data;
    wire [7:0] palette_index;
    wire [8:0] palette_rgb;
    integer planes = 0, palettes = 0, payload_bytes = 0, i;
    reg [63:0] first_word, second_word;
    reg [15:0] first_address, second_address;
    reg [8:0] palette_last;

    nexttang_spec256_uart_loader dut (
        .clock(clock), .reset(reset), .byte_in(byte_in), .byte_valid(valid),
        .payload(payload), .spec256_mode(mode),
        .plane_write(plane_write), .plane_address(plane_address), .plane_data(plane_data),
        .palette_write(palette_write), .palette_index(palette_index), .palette_rgb(palette_rgb),
        .arm(arm), .arm_pc(arm_pc), .disarm(disarm));

    always #5 clock = ~clock;

    task send(input [7:0] b);
        begin
            @(negedge clock); byte_in = b; valid = 1;
            @(negedge clock); valid = 0;
            repeat (3) @(negedge clock);
        end
    endtask
    task send_string(input [8*16-1:0] s, input integer n);
        integer j;
        for (j = n - 1; j >= 0; j = j - 1) send(s[8*j +: 8]);
    endtask

    always @(posedge clock) begin
        if (valid && payload) payload_bytes = payload_bytes + 1;
        if (plane_write) begin
            if (planes == 0) begin first_word = plane_data; first_address = plane_address; end
            if (planes == 1) begin second_word = plane_data; second_address = plane_address; end
            planes = planes + 1;
        end
        if (palette_write) begin
            palettes = palettes + 1;
            if (palette_index == 8'hff) palette_last = palette_rgb;
        end
    end

    initial begin
        repeat (3) @(negedge clock); reset = 0;
        send_string("S1", 2);
        if (mode !== 1) $fatal(1, "S1 did not set the mode");
        // Two words at 0x4000: bytes 'K','S','G',1..5 then 8..15.
        send_string("W40000002", 9);
        send("K"); send("S"); send("G");
        for (i = 1; i <= 5; i = i + 1) send(i);
        for (i = 8; i <= 15; i = i + 1) send(i);
        // Palette: entry n = n + 0x100 for even n, so the high bit shows.
        send("Q");
        for (i = 0; i < 256; i = i + 1) begin send(i); send(1); end
        send_string("Gab12", 5);
        send("H");
        send_string("S0", 2);
        $display("LOADER planes %0d palettes %0d payload %0d mode %0d armpc %h", planes, palettes, payload_bytes, mode, arm_pc);
        $display("WORDS %h@%h %h@%h LASTPAL %h", first_word, first_address, second_word, second_address, palette_last);
        $finish;
    end
endmodule
"""


class Spec256UartLoaderTest(unittest.TestCase):
    def test_loader_commands(self) -> None:
        output = run_testbench(TESTBENCH, *SOURCES)
        self.assertIn("LOADER planes 2 palettes 256 payload 528 mode 0 armpc ab12", output, output)
        self.assertIn("WORDS 0504030201474b53@4000".replace("474b53", "47534b"), output, output)
        self.assertIn("0f0e0d0c0b0a0908@4001 LASTPAL 1ff", output, output)


if __name__ == "__main__":
    unittest.main()
