"""The Spec256 overlay must colour exactly the paper, from the right plane bits.

rtl/video/nexttang_spec256_overlay.v replaces captured pixels inside the
256 x 192 paper at (52, 48) of the 360 x 288 window. The testbench sweeps the
whole window at 7 MHz, serves plane words one 28 MHz cycle after each
address as the mirror does, and checks every output pixel against an
independent model: the display-file address in its arithmetic form, the index
built from bit (7 - x mod 8) of each plane's byte, 0xFF passing the core's
pixel through, and everything outside the paper, or with the overlay off,
unchanged. Outputs must keep their own coordinates.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (REPO_ROOT / "rtl" / "video" / "nexttang_spec256_overlay.v",)

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock_28 = 0, clock_7 = 0, reset = 1, enable = 1;
    reg frame_start = 0, valid = 0;
    reg [8:0] cx = 0, cy = 0, cpixel = 0;
    wire o_frame, o_valid;
    wire [8:0] ox, oy, opixel;
    wire [15:0] plane_address;
    reg [63:0] plane_data = 0;
    reg palette_write = 0;
    reg [7:0] palette_index = 0;
    reg [8:0] palette_rgb = 0;
    integer checked = 0, coloured = 0, passed_ff = 0, entry;

    nexttang_spec256_overlay dut (
        .clock_7(clock_7), .clock_28(clock_28), .reset(reset), .enable(enable),
        .capture_frame_start(frame_start), .capture_pixel_valid(valid),
        .capture_x(cx), .capture_y(cy), .capture_pixel(cpixel),
        .frame_start(o_frame), .pixel_valid(o_valid), .x(ox), .y(oy), .pixel(opixel),
        .plane_address(plane_address), .plane_data(plane_data),
        .palette_write(palette_write), .palette_index(palette_index), .palette_rgb(palette_rgb));

    // 28 MHz, and 7 MHz rising on every fourth 28 MHz rising edge.
    integer phase = 0;
    always #17.857 begin
        clock_28 = ~clock_28;
        if (clock_28) begin
            phase = (phase + 1) % 4;
            if (phase == 0) clock_7 = 1;
            if (phase == 2) clock_7 = 0;
        end
    end

    // Plane byte k at Spectrum address a; some words are all 0xFF.
    function [7:0] plane_byte(input [15:0] a, input integer k);
        plane_byte = (a % 97 == 5) ? 8'hff : ((a * 7 + k * 31) & 8'hff);
    endfunction
    function [8:0] palette_of(input [7:0] i);
        palette_of = {1'b0, i} ^ 9'h155;
    endfunction
    function [8:0] core_pixel(input [8:0] x, input [8:0] y);
        core_pixel = (x * 3 + y * 5) & 9'h1ff;
    endfunction

    // The mirror's port B: the word for the address of the last edge.
    integer lane;
    always @(posedge clock_28)
        for (lane = 0; lane < 8; lane = lane + 1)
            plane_data[8 * lane +: 8] <= plane_byte(plane_address, lane);

    // The expected pixel, from the model.
    function [8:0] expected(input [8:0] x, input [8:0] y, input on);
        integer px, py, a, j;
        reg [7:0] index, b;
        begin
            if (!on || x < 52 || x >= 308 || y < 48 || y >= 240) begin
                expected = core_pixel(x, y);
            end else begin
                px = x - 52; py = y - 48;
                a = 16'h4000 + ((py & 8'hc0) << 5) + ((py & 7) << 8) + ((py & 8'h38) << 2) + (px >> 3);
                for (j = 0; j < 8; j = j + 1) begin
                    b = plane_byte(a, j);
                    index[j] = b[7 - (px % 8)];
                end
                expected = index == 8'hff ? core_pixel(x, y) : palette_of(index);
            end
        end
    endfunction

    task sweep(input on);
        integer x, y;
        begin
            enable = on;
            for (y = 0; y < 288; y = y + 1)
                for (x = 0; x < 360; x = x + 1) begin
                    @(posedge clock_7); #1;
                    cx = x; cy = y; valid = 1; frame_start = x == 0 && y == 0;
                    cpixel = core_pixel(x, y);
                end
            @(posedge clock_7); #1 valid = 0;
            repeat (3) @(posedge clock_7);
        end
    endtask

    // Check every output against the model; a frame start must travel with
    // pixel (0, 0).
    always @(posedge clock_7) begin
        #2;
        if (o_valid) begin
            if (opixel !== expected(ox, oy, enable))
                $fatal(1, "pixel (%0d,%0d) was %h, expected %h", ox, oy, opixel, expected(ox, oy, enable));
            if (o_frame !== (ox == 0 && oy == 0))
                $fatal(1, "frame start out of step at (%0d,%0d)", ox, oy);
            checked = checked + 1;
            if (enable && ox >= 52 && ox < 308 && oy >= 48 && oy < 240) begin
                if (opixel === core_pixel(ox, oy)) passed_ff = passed_ff + 1;
                else coloured = coloured + 1;
            end
        end
    end

    initial begin
        repeat (4) @(posedge clock_28);
        reset = 0;
        for (entry = 0; entry < 256; entry = entry + 1) begin
            @(negedge clock_28);
            palette_write = 1; palette_index = entry; palette_rgb = palette_of(entry);
        end
        @(negedge clock_28) palette_write = 0;
        sweep(1);
        sweep(0);
        $display("OVERLAY_PASS checked %0d coloured %0d passthrough %0d", checked, coloured, passed_ff);
        $finish;
    end
endmodule
"""


class Spec256OverlayTest(unittest.TestCase):
    def test_overlay_colours_the_paper_from_the_planes(self) -> None:
        output = run_testbench(TESTBENCH, *SOURCES)
        self.assertIn("OVERLAY_PASS", output, output)
        counts = output.split("OVERLAY_PASS ")[1].split()
        checked, coloured, passthrough = int(counts[1]), int(counts[3]), int(counts[5])
        self.assertEqual(checked, 2 * 360 * 288, output)
        self.assertGreater(coloured, 40000, output)
        self.assertGreater(passthrough, 100, output)


if __name__ == "__main__":
    unittest.main()
