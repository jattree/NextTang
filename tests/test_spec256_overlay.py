"""The Spec256 overlay must colour exactly the paper, from the right plane bits.

rtl/video/nexttang_spec256_overlay.v replaces captured pixels inside the
256 x 192 paper at (52, 48) of the 360 x 288 window. The testbench sweeps the
whole window at 7 MHz, serves plane words one 28 MHz cycle after each
address as the mirror does, and checks every output pixel against an
independent model: the display-file address in its arithmetic form, the index
built from bit (7 - x mod 8) of each plane's byte, 0xFF passing the core's
pixel through, and everything outside the paper, or with the overlay off,
unchanged. Outputs must keep their own coordinates.

A third sweep runs the Spec256 DOS rule: indices 0xC0 to 0xFF take the cell's
ink from the attributes, which the overlay copies from bank 5 writes to
0x1800-0x1AFF; writes elsewhere in bank 5 that share those low address bits
must not reach the copy, and 0xFF no longer passes the core's pixel.

Two more sweeps run with a background loaded (with zeros in it): in DOS mode
index 0 shows the background; otherwise a non-zero background shows where the
index is 0, or 0xFF in a cell whose ink is not 7 when BkOverFF is set.
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
    reg render_dos = 0, bank5_write = 0, bk_over_ff = 0;
    reg background_present = 0, background_write = 0;
    reg [15:0] background_address = 0;
    reg [7:0] background_index = 0;
    integer shown_background = 0;
    reg [13:0] bank5_address = 0;
    reg [7:0] bank5_data = 0;
    integer checked = 0, coloured = 0, passed_ff = 0, inked = 0, entry;

    nexttang_spec256_overlay dut (
        .clock_7(clock_7), .clock_28(clock_28), .reset(reset), .enable(enable),
        .capture_frame_start(frame_start), .capture_pixel_valid(valid),
        .capture_x(cx), .capture_y(cy), .capture_pixel(cpixel),
        .frame_start(o_frame), .pixel_valid(o_valid), .x(ox), .y(oy), .pixel(opixel),
        .plane_address(plane_address), .plane_data(plane_data),
        .palette_write(palette_write), .palette_index(palette_index), .palette_rgb(palette_rgb),
        .render_dos(render_dos), .bk_over_ff(bk_over_ff),
        .background_present(background_present), .background_write(background_write),
        .background_address(background_address), .background_index(background_index),
        .bank5_write(bank5_write), .bank5_address(bank5_address),
        .bank5_data(bank5_data));

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
    function [7:0] background_of(input integer px, input integer py);
        background_of = (px + py) % 7 == 0 ? 8'h00 : ((px * 5 + py * 3) & 8'hff);
    endfunction
    function [7:0] attribute_of(input integer block);
        attribute_of = (block * 37 + 5) & 8'hff;
    endfunction

    // The mirror's port B: the word for the address of the last edge.
    integer lane;
    always @(posedge clock_28)
        for (lane = 0; lane < 8; lane = lane + 1)
            plane_data[8 * lane +: 8] <= plane_byte(plane_address, lane);

    // The expected pixel, from the model.
    function [8:0] expected(input [8:0] x, input [8:0] y, input on, input dos);
        integer px, py, a, j;
        reg [7:0] index, b, ink;
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
                ink = attribute_of((py / 8) * 32 + px / 8);
                if (background_present &&
                    (dos ? index == 8'h00
                         : background_of(px, py) != 8'h00 &&
                           (index == 8'h00 || (index == 8'hff && bk_over_ff && ink[2:0] != 3'd7))))
                    expected = palette_of(background_of(px, py));
                else if (dos && index[7:6] == 2'b11)
                    expected = palette_of({2'b11, ink[2:0], index[2:0]});
                else if (dos)
                    expected = palette_of(index);
                else
                    expected = index == 8'hff ? core_pixel(x, y) : palette_of(index);
            end
        end
    endfunction

    task sweep(input on, input dos);
        integer x, y;
        begin
            enable = on;
            render_dos = dos;
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
            if (opixel !== expected(ox, oy, enable, render_dos))
                $fatal(1, "pixel (%0d,%0d) was %h, expected %h", ox, oy, opixel,
                       expected(ox, oy, enable, render_dos));
            if (o_frame !== (ox == 0 && oy == 0))
                $fatal(1, "frame start out of step at (%0d,%0d)", ox, oy);
            checked = checked + 1;
            if (enable && !render_dos && ox >= 52 && ox < 308 && oy >= 48 && oy < 240) begin
                if (opixel === core_pixel(ox, oy)) passed_ff = passed_ff + 1;
                else coloured = coloured + 1;
            end
            if (enable && render_dos && !background_present && ox >= 52 && ox < 308 &&
                oy >= 48 && oy < 240 && opixel !== expected(ox, oy, 1, 0))
                inked = inked + 1;
            if (enable && background_present && ox >= 52 && ox < 308 && oy >= 48 && oy < 240 &&
                opixel === palette_of(background_of(ox - 52, oy - 48)) &&
                background_of(ox - 52, oy - 48) != 8'h00)
                shown_background = shown_background + 1;
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
        // The attributes, then writes that share their low ten address bits
        // (0x1400 up, 0x1C00 up) and must be ignored.
        for (entry = 0; entry < 768; entry = entry + 1) begin
            @(negedge clock_28);
            bank5_write = 1; bank5_address = 14'h1800 + entry; bank5_data = attribute_of(entry);
        end
        for (entry = 0; entry < 768; entry = entry + 1) begin
            @(negedge clock_28);
            bank5_address = (entry & 1 ? 14'h1c00 : 14'h1400) + entry; bank5_data = 8'h00;
        end
        @(negedge clock_28) bank5_write = 0;
        sweep(1, 0);
        sweep(0, 0);
        sweep(1, 1);
        for (entry = 0; entry < 49152; entry = entry + 1) begin
            @(negedge clock_28);
            background_write = 1; background_address = entry;
            background_index = background_of(entry % 256, entry / 256);
        end
        @(negedge clock_28) background_write = 0;
        background_present = 1;
        sweep(1, 1);
        bk_over_ff = 1;
        sweep(1, 0);
        $display("OVERLAY_PASS checked %0d coloured %0d passthrough %0d inked %0d background %0d",
                 checked, coloured, passed_ff, inked, shown_background);
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
        inked, background = int(counts[7]), int(counts[9])
        self.assertEqual(checked, 5 * 360 * 288, output)
        self.assertGreater(background, 1000, output)
        self.assertGreater(coloured, 40000, output)
        self.assertGreater(passthrough, 100, output)
        # Pixels the DOS rule changed: every 0xC0-0xFF index whose ink is not
        # already its bits 5:3, and every former passthrough.
        self.assertGreater(inked, 5000, output)


if __name__ == "__main__":
    unittest.main()
