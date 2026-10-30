"""The Spec256 UART loader must turn its commands into plane, palette and arm writes.

rtl/input/nexttang_spec256_uart_loader.v is fed bytes as the UART receiver
gives them. Raw plane and palette bytes, including ones that look like other
commands ("R", "S", "G"), must land as data while payload is high, and the
mode, rules flags, CFG, arm and disarm commands must act. A background's
49152 bytes, including command letters, land in order as background writes,
and H drops the background.
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
    wire [7:0] rules_flags;
    wire background_write, background_present;
    wire [15:0] background_address;
    wire [7:0] background_index;
    wire [23:0] cfg;
    integer backgrounds = 0, background_errors = 0;
    integer planes = 0, palettes = 0, payload_bytes = 0, i;
    reg [63:0] first_word, second_word;
    reg [15:0] first_address, second_address;
    reg [8:0] palette_last;

    nexttang_spec256_uart_loader dut (
        .clock(clock), .reset(reset), .byte_in(byte_in), .byte_valid(valid),
        .payload(payload), .spec256_mode(mode),
        .plane_write(plane_write), .plane_address(plane_address), .plane_data(plane_data),
        .palette_write(palette_write), .palette_index(palette_index), .palette_rgb(palette_rgb),
        .arm(arm), .arm_pc(arm_pc), .disarm(disarm), .rules_flags(rules_flags),
        .background_write(background_write), .background_address(background_address),
        .background_index(background_index), .background_present(background_present), .cfg(cfg));

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
        if (background_write) begin
            if (background_address !== backgrounds[15:0] ||
                background_index !== ((backgrounds * 7 + 3) & 8'hff))
                background_errors = background_errors + 1;
            backgrounds = backgrounds + 1;
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
        if (rules_flags !== 8'h00) $fatal(1, "rules flags not clear after reset");
        send_string("U5A", 3);
        if (rules_flags !== 8'h5a) $fatal(1, "U5A set the rules flags to %h", rules_flags);
        send_string("Uz", 2);
        if (rules_flags !== 8'h5a) $fatal(1, "a bad digit changed the rules flags");
        // Two words at 0x4000: bytes 'R','S','G',1..5 then 8..15.
        send_string("W40000002", 9);
        send("R"); send("S"); send("G");
        for (i = 1; i <= 5; i = i + 1) send(i);
        for (i = 8; i <= 15; i = i + 1) send(i);
        if (rules_flags !== 8'h5a) $fatal(1, "plane bytes changed the rules flags");
        // Palette: entry n = n + 0x100 for even n, so the high bit shows.
        send("Q");
        for (i = 0; i < 256; i = i + 1) begin send(i); send(1); end
        send_string("C40880a", 7);
        if (cfg !== 24'h40880a) $fatal(1, "C set the CFG to %h", cfg);
        send("B");
        if (background_present !== 1) $fatal(1, "B did not mark a background");
        for (i = 0; i < 49152; i = i + 1) begin
            @(negedge clock); byte_in = (i * 7 + 3) & 8'hff; valid = 1;
            @(negedge clock); valid = 0;
        end
        repeat (3) @(negedge clock);
        if (payload !== 0) $fatal(1, "still in payload after the background");
        send_string("Gab12", 5);
        send("H");
        if (background_present !== 0) $fatal(1, "H kept the background");
        send_string("S0", 2);
        $display("LOADER planes %0d palettes %0d payload %0d mode %0d armpc %h", planes, palettes, payload_bytes, mode, arm_pc);
        $display("WORDS %h@%h %h@%h LASTPAL %h", first_word, first_address, second_word, second_address, palette_last);
        $display("BACKGROUND %0d errors %0d", backgrounds, background_errors);
        $finish;
    end
endmodule
"""


class Spec256UartLoaderTest(unittest.TestCase):
    def test_loader_commands(self) -> None:
        output = run_testbench(TESTBENCH, *SOURCES)
        self.assertIn("LOADER planes 2 palettes 256 payload 49680 mode 0 armpc ab12", output, output)
        self.assertIn("BACKGROUND 49152 errors 0", output, output)
        # The first word's bytes, last byte first: 1..5 after 'G', 'S', 'R'.
        self.assertIn("WORDS 0504030201475352@4000", output, output)
        self.assertIn("0f0e0d0c0b0a0908@4001 LASTPAL 1ff", output, output)


if __name__ == "__main__":
    unittest.main()
