"""The Spec256 overlay must colour exactly the paper, from the right plane bits.

rtl/video/nexttang_spec256_overlay.v replaces captured pixels inside the
256 x 192 paper at (paper_left, paper_top) of the 360 x 288 window, here
(52, top). The testbench sweeps the whole window at 7 MHz, serves plane words one 28 MHz cycle after each
address as the mirror does, and checks every output pixel against an
independent model: the display-file address in its arithmetic form, the index
built from bit (7 - x mod 8) of each plane's byte, 0xFF passing the core's
pixel through, and everything outside the paper, or with the overlay off,
unchanged. Outputs must keep their own coordinates.

The last sweep moves the paper up to line 24, where the 60 Hz timing puts it.
Two EmuZWin sweeps mix indices at or above 256 - UpColorsMixed and below
DownColorsMixed with the cell's ink, then with its paper and BRIGHT.
Three ZX-Poly sweeps follow (modes 4, 6, 7): colour I G R B from planes 3-0 at
the Spectrum's levels, cells with ink = paper filled with the ink in modes 6
and 7, and in mode 7 cells without FLASH left as the core drew them.

A third sweep runs the Spec256 DOS rule: indices 0xC0 to 0xFF take the cell's
ink from the attributes, which the overlay copies from bank 5 writes to
0x1800-0x1AFF; writes elsewhere in bank 5 that share those low address bits
must not reach the copy, and 0xFF no longer passes the core's pixel.

Two more sweeps run with a background loaded (with zeros in it): in DOS mode
index 0 shows the background; otherwise a non-zero background shows where the
index is 0, or 0xFF in a cell whose ink is not 7 when BkOverFF is set.

A sweep sets attr_hide (RUL1 flag bit 5): every cell whose ink equals its
paper shows the core's pixel whatever its index.

The overlay counts frames. In the flash's on phase (bit 4 of the count set,
here after frame starts given without pixels) four sweeps follow: without
flash_blink (OPT1 byte 8 bit 0) nothing changes; with it every cell with FLASH
shows the core's pixel instead of its colour, but not in ZX-Poly modes (4 and
7 swept), as SPEC256_MISTER does. Every earlier sweep falls in the off phase.
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
    reg render_dos = 0, bank5_write = 0, bk_over_ff = 0, attr_hide = 0, flash_blink = 0;
    integer hidden = 0, flashed = 0;
    reg [4:0] frames = 0;               // the model's count of frame starts
    reg [8:0] top = 9'd48;
    reg [2:0] zxpoly = 3'd0;
    reg [23:0] cfg = 24'd0;
    integer zxpoly_plain = 0, zxpoly_filled = 0;
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
        .paper_top(top), .paper_left(9'd52), .render_dos(render_dos), .attr_hide(attr_hide), .flash_blink(flash_blink), .zxpoly_mode(zxpoly), .bk_over_ff(bk_over_ff), .cfg(cfg),
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
    function [8:0] spectrum_rgb(input [2:0] colour, input bright);
        reg [2:0] level;
        begin
            level = bright ? 3'd7 : 3'd6;
            spectrum_rgb = {colour[1] ? level : 3'd0, colour[2] ? level : 3'd0,
                            colour[0] ? level : 3'd0};
        end
    endfunction
    function [8:0] mixed(input [8:0] rgb, input [2:0] colour, input bright);
        integer level, r, g, b;
        begin
            level = bright ? 7 : 5;
            r = (rgb[8:6] + (colour[1] ? level : 0)) / 2;
            g = (rgb[5:3] + (colour[2] ? level : 0)) / 2;
            b = (rgb[2:0] + (colour[0] ? level : 0)) / 2;
            mixed = {r[2:0], g[2:0], b[2:0]};
        end
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
            if (!on || x < 52 || x >= 308 || y < top || y >= top + 192) begin
                expected = core_pixel(x, y);
            end else begin
                px = x - 52; py = y - top;
                a = 16'h4000 + ((py & 8'hc0) << 5) + ((py & 7) << 8) + ((py & 8'h38) << 2) + (px >> 3);
                for (j = 0; j < 8; j = j + 1) begin
                    b = plane_byte(a, j);
                    index[j] = b[7 - (px % 8)];
                end
                ink = attribute_of((py / 8) * 32 + px / 8);
                if (attr_hide && ink[2:0] == ink[5:3])
                    expected = core_pixel(x, y);
                else if (flash_blink && ink[7] && frames[4] && zxpoly == 3'd0)
                    expected = core_pixel(x, y);
                else if (zxpoly != 3'd0) begin
                    if (zxpoly == 3'd7 && !ink[7])
                        expected = core_pixel(x, y);
                    else if (zxpoly[1] && ink[2:0] == ink[5:3])
                        expected = spectrum_rgb(ink[2:0], ink[6]);
                    else
                        expected = spectrum_rgb(index[2:0], index[3]);
                end else if (background_present &&
                    (dos ? index == 8'h00
                         : background_of(px, py) != 8'h00 &&
                           (index == 8'h00 || (index == 8'hff && bk_over_ff && ink[2:0] != 3'd7))))
                    expected = palette_of(background_of(px, py));
                else if (dos && index[7:6] == 2'b11)
                    expected = palette_of({2'b11, ink[2:0], index[2:0]});
                else if (dos)
                    expected = palette_of(index);
                else if (index != 8'hff && cfg[7] &&
                         (index >= 256 - cfg[23:16] || index < cfg[15:8]))
                    expected = mixed(palette_of(index), cfg[1] ? ink[5:3] : ink[2:0],
                                     cfg[0] && ink[6]);
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
            frames = frames + 1;
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

    // Frame starts without a picture, to move the flash phase on.
    task frame_starts(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clock_7); #1 frame_start = 1; frames = frames + 1;
                @(posedge clock_7); #1 frame_start = 0;
            end
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
            if (enable && flash_blink && frames[4] && zxpoly == 3'd0 && ox >= 52 && ox < 308 && oy >= top &&
                oy < top + 192 && attribute_of(((oy - top) / 8) * 32 + (ox - 52) / 8) >= 8'h80)
                flashed = flashed + 1;
            if (enable && attr_hide && ox >= 52 && ox < 308 && oy >= top && oy < top + 192 &&
                attribute_of(((oy - top) / 8) * 32 + (ox - 52) / 8) % 8 ==
                (attribute_of(((oy - top) / 8) * 32 + (ox - 52) / 8) / 8) % 8)
                hidden = hidden + 1;
            if (enable && !render_dos && ox >= 52 && ox < 308 && oy >= top && oy < top + 192) begin
                if (opixel === core_pixel(ox, oy)) passed_ff = passed_ff + 1;
                else coloured = coloured + 1;
            end
            if (enable && render_dos && !background_present && ox >= 52 && ox < 308 &&
                oy >= top && oy < top + 192 && opixel !== expected(ox, oy, 1, 0))
                inked = inked + 1;
            if (enable && background_present && ox >= 52 && ox < 308 && oy >= top && oy < top + 192 &&
                opixel === palette_of(background_of(ox - 52, oy - top)) &&
                background_of(ox - 52, oy - top) != 8'h00)
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
        // The 60 Hz paper, 24 lines higher.
        top = 9'd24;
        sweep(1, 1);
        top = 9'd48;
        background_present = 0; bk_over_ff = 0;
        cfg = 24'h400880; sweep(1, 0);
        cfg = 24'h010083; sweep(1, 0);
        cfg = 24'd0;
        zxpoly = 3'd4; sweep(1, 0);
        zxpoly = 3'd6; sweep(1, 0);
        zxpoly = 3'd7; sweep(1, 0);
        zxpoly = 3'd0;
        attr_hide = 1; sweep(1, 0); attr_hide = 0;
        if (hidden == 0) $fatal(1, "no cell with ink = paper was swept with attr_hide");
        if (frames[4]) $fatal(1, "an earlier sweep fell in the flash's on phase");
        // Into the flash's on phase, then a sweep.
        frame_starts(16 - frames[3:0]);
        if (!frames[4]) $fatal(1, "flash phase not reached");
        sweep(1, 0);                                   // the option off: unchanged
        flash_blink = 1;
        sweep(1, 0);
        zxpoly = 3'd4; sweep(1, 0);
        zxpoly = 3'd7; sweep(1, 0);
        zxpoly = 3'd0; flash_blink = 0;
        if (!frames[4]) $fatal(1, "left the flash phase");
        if (flashed == 0) $fatal(1, "no FLASH cell was swept in the on phase");
        $display("OVERLAY_PASS checked %0d coloured %0d passthrough %0d inked %0d background %0d hidden %0d flashed %0d",
                 checked, coloured, passed_ff, inked, shown_background, hidden, flashed);
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
        self.assertEqual(checked, 16 * 360 * 288, output)
        self.assertGreater(int(counts[13]), 10000, output)   # pixels in FLASH cells, on phase
        self.assertGreater(background, 1000, output)
        self.assertGreater(coloured, 40000, output)
        self.assertGreater(passthrough, 100, output)
        # Pixels the DOS rule changed: every 0xC0-0xFF index whose ink is not
        # already its bits 5:3, and every former passthrough.
        self.assertGreater(inked, 5000, output)


if __name__ == "__main__":
    unittest.main()
