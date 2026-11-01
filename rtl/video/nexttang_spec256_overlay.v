// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Spec256's colour picture, laid over the Next core's captured raster.
//
// The core's picture is captured at 7 MHz as a 360 x 288 window
// (nexttang_ula_capture), the Spectrum's 256 x 192 paper at (paper_left,
// paper_top): the paper moves with the core's 50/60 Hz timing, so the board
// measures both from the ULA's counters (48 is the 50 Hz top). For
// each paper pixel this reads the colour planes' word for its screen byte
// (one byte per plane, from the Layer 2 mirror's port B in Spec256 mode),
// takes the pixel's bit from each plane as an 8-bit palette index, and
// replaces the core's pixel:
//
//   index 0xFF   the core's own pixel, as Spec256 shows the original
//                Spectrum graphics where a game's colours leave them
//   index 0      the background; palette entry 0 until backgrounds exist
//   otherwise    the palette entry
//
// With attr_hide (the .256's RUL1 flag bit 5, as SPEC256_MISTER's ATTR_HIDE)
// a cell whose ink equals its paper shows the core's pixel whatever its index:
// what a game hides with the attribute (sprites entering at the sides of the
// play area, for example) stays hidden.
//
// With render_dos (the .256's RUL1 flag for Spec256 DOS v1.2 games) indices
// 0xC0 to 0xFF take the cell's attribute ink instead: palette entry
// 11 iii xxx, iii the ink and xxx the index's low bits, so a game's text
// keeps the colours its attributes give it. 0xFF is then such an entry too,
// not the core's pixel. The ink comes from a copy of the attributes
// (bank 5, 0x1800 to 0x1AFF), kept from the core's writes to bank 5.
//
// With a background loaded (256 x 192 palette indices, 0 meaning none) a
// paper pixel shows it, as SPEC256_MISTER's video does:
//   DOS render   where the index is 0 (background index 0 is palette 0)
//   otherwise    where the background is not 0 and the index is 0, or the
//                index is 0xFF with the .CFG's BkOverFF and an ink other
//                than 7 (cells drawn in white keep the Spectrum's pixels)
//
// Games with a .CFG (EmuZWin colourings; cfg flags bit 7) mix colours with the
// attribute, as SPEC256_MISTER does outside the DOS render: an index at or
// above 256 - UpColorsMixed, or below DownColorsMixed, shows the average of
// its palette colour and the cell's ink (its paper with UpMixPaper, flags bit
// 1) at level 0xBF (0xFF in a BRIGHT cell with UseBrightInMix, bit 0). 0xFF
// still shows the core's pixel, and the background is never mixed.
//
// ZX-Poly games (RUL1 byte 7, zxpoly_mode 4, 6 or 7; Igor Maznitsa's
// ZX-Poly converted by Alberto Conde's tools) colour a pixel with the Spectrum
// colour I G R B taken from planes 3, 2, 1 and 0, at the Spectrum's two
// levels. Mode 6 fills a cell whose ink equals its paper with the ink; mode 7
// does both only in cells with FLASH and shows every other cell as the
// Spectrum does (the core's own pixel). As SPEC256_MISTER's video.
//
// FLASH: neither the DOS Spec256 nor EmuZWin blinks a coloured pixel, so by
// default FLASH changes nothing here. A game built to ask for it (OPT1 byte 8
// bit 0, flash_blink, agreed with Alberto Conde) shows the core's own pixel
// in a cell with FLASH during the flash's on phase (bit 4 of a count of
// frames, 16 frames on, 16 off, as SPEC256_MISTER's flash_count), so a
// coloured line it marks with FLASH (the Ultimate games' selected menu
// option) blinks as on the Spectrum. ZX-Poly mode 7, where FLASH marks the
// coloured cells, is left alone.
//
// Outside the paper, or with enable low, the core's pixel passes through.
// Everything leaves two 7 MHz cycles after it arrived, the capture's own
// signals with it. The palette is RGB333, the frame store's pixel; a writer
// on the 28 MHz side fills it.

`default_nettype none

module nexttang_spec256_overlay (
    input  wire        clock_7,
    input  wire        clock_28,
    input  wire        reset,
    input  wire        enable,
    input  wire [8:0]  paper_top,
    input  wire [8:0]  paper_left,

    input  wire        capture_frame_start,
    input  wire        capture_pixel_valid,
    input  wire [8:0]  capture_x,
    input  wire [8:0]  capture_y,
    input  wire [8:0]  capture_pixel,

    output reg         frame_start,
    output reg         pixel_valid,
    output reg  [8:0]  x,
    output reg  [8:0]  y,
    output reg  [8:0]  pixel,

    // The planes: Spectrum address out, the eight planes' bytes back a
    // 28 MHz cycle later (lane k in bits 8k+7:8k).
    output wire [15:0] plane_address,
    input  wire [63:0] plane_data,

    input  wire        palette_write,
    input  wire [7:0]  palette_index,
    input  wire [8:0]  palette_rgb,

    input  wire        render_dos,
    input  wire        attr_hide,
    input  wire        flash_blink,
    input  wire [2:0]  zxpoly_mode,
    input  wire        bk_over_ff,
    // The .CFG: UpColorsMixed, DownColorsMixed, flags (bit 0 UseBrightInMix,
    // bit 1 UpMixPaper, bit 7 present).
    input  wire [23:0] cfg,

    // The background, written on clock_28; pixel (x, y) is word y * 256 + x.
    input  wire        background_present,
    input  wire        background_write,
    input  wire [15:0] background_address,
    input  wire [7:0]  background_index,

    // Bank 5 writes, on clock_28, as the core's bank 5 RAM takes them.
    input  wire        bank5_write,
    input  wire [13:0] bank5_address,
    input  wire [7:0]  bank5_data
);
    wire [8:0] paper_x = capture_x - paper_left;
    wire [8:0] paper_y = capture_y - paper_top;
    wire in_paper = capture_x >= paper_left && capture_x < paper_left + 9'd256 &&
                    capture_y >= paper_top && capture_y < paper_top + 9'd192;

    // The Spectrum's display file: 010 y7 y6 y2 y1 y0 y5 y4 y3 x7 x6 x5 x4 x3.
    assign plane_address = {3'b010, paper_y[7:6], paper_y[2:0], paper_y[5:3], paper_x[7:3]};

    reg [8:0] palette [0:255];
    always @(posedge clock_28)
        if (palette_write)
            palette[palette_index] <= palette_rgb;

    // The attributes, read a 28 MHz cycle after the address like the planes.
    // Cell (row, column) is attribute row * 32 + column; for 0x1800 to
    // 0x1AFF that is the address's low ten bits.
    reg [7:0] attributes [0:767];
    reg [7:0] attribute_q = 8'd0;
    wire [9:0] attribute_read_index = {paper_y[7:3], paper_x[7:3]};
    always @(posedge clock_28) begin
        if (bank5_write && bank5_address[13:8] >= 6'h18 && bank5_address[13:8] < 6'h1b)
            attributes[bank5_address[9:0]] <= bank5_data;
        attribute_q <= attributes[attribute_read_index];
    end

    reg [7:0] background [0:49151];
    reg [7:0] background_q = 8'd0;
    always @(posedge clock_28) begin
        if (background_write)
            background[background_address] <= background_index;
        background_q <= background[{paper_y[7:0], paper_x[7:0]}];
    end

    // Frames counted for FLASH; capture_frame_start comes once a frame.
    reg [4:0] flash_count = 5'd0;
    always @(posedge clock_7)
        if (reset)
            flash_count <= 5'd0;
        else if (capture_frame_start)
            flash_count <= flash_count + 5'd1;

    // Stage 1: the pixel and its plane word.
    reg        s1_frame_start, s1_valid, s1_paper;
    reg [8:0]  s1_x, s1_y, s1_pixel;
    reg [2:0]  s1_bit;
    reg [63:0] s1_word;
    reg [2:0]  s1_ink;
    reg [7:0]  s1_attribute;
    reg [7:0]  s1_background;

    always @(posedge clock_7) begin
        if (reset) begin
            s1_frame_start <= 1'b0;
            s1_valid <= 1'b0;
            s1_paper <= 1'b0;
            frame_start <= 1'b0;
            pixel_valid <= 1'b0;
        end else begin
            s1_frame_start <= capture_frame_start;
            s1_valid <= capture_pixel_valid;
            s1_paper <= enable && in_paper;
            s1_x <= capture_x;
            s1_y <= capture_y;
            s1_pixel <= capture_pixel;
            s1_bit <= 3'd7 - paper_x[2:0];
            s1_word <= plane_data;
            s1_ink <= attribute_q[2:0];
            s1_attribute <= attribute_q;
            s1_background <= background_q;

            frame_start <= s1_frame_start;
            pixel_valid <= s1_valid;
            x <= s1_x;
            y <= s1_y;
            if (!s1_paper)
                pixel <= s1_pixel;
            else if (attr_hide && s1_attribute[2:0] == s1_attribute[5:3])
                pixel <= s1_pixel;
            else if (flash_blink && s1_attribute[7] && flash_count[4] && zxpoly_mode != 3'd7)
                pixel <= s1_pixel;
            else if (zxpoly_on)
                pixel <= zxpoly_plain ? s1_pixel : spectrum_rgb(zxpoly_colour, zxpoly_bright);
            else if (show_background)
                pixel <= palette[s1_background];
            else if (!render_dos && index == 8'hff)
                pixel <= s1_pixel;
            else if (render_dos && index[7:6] == 2'b11)
                pixel <= palette[{2'b11, s1_ink, index[2:0]}];
            else if (mix_now)
                pixel <= mixed(palette[index], mix_colour, mix_bright);
            else
                pixel <= palette[index];
        end
    end

    // ZX-Poly: the cell's own Spectrum colours where it is plain (mode 7
    // without FLASH), its ink where ink = paper (modes 6 and 7), else I G R B.
    wire zxpoly_on = zxpoly_mode != 3'd0;
    wire zxpoly_plain = zxpoly_mode == 3'd7 && !s1_attribute[7];
    wire zxpoly_fill = zxpoly_mode[1] && s1_attribute[2:0] == s1_attribute[5:3];
    wire [2:0] zxpoly_colour = zxpoly_fill ? s1_attribute[2:0] : index[2:0];
    wire zxpoly_bright = zxpoly_fill ? s1_attribute[6] : index[3];

    // A Spectrum colour (G R B in bits 2:0) as RGB333: 0xD7 is 6, 0xFF is 7.
    function [8:0] spectrum_rgb(input [2:0] colour, input bright);
        reg [2:0] level;
        begin
            level = bright ? 3'd7 : 3'd6;
            spectrum_rgb = {colour[1] ? level : 3'd0, colour[2] ? level : 3'd0,
                            colour[0] ? level : 3'd0};
        end
    endfunction

    // EmuZWin mixing with the attribute.
    wire [8:0] mix_low = 9'd256 - {1'b0, cfg[23:16]};
    wire mix_now = cfg[7] && !render_dos &&
                   ({1'b0, index} >= mix_low || index < cfg[15:8]);
    wire [2:0] mix_colour = cfg[1] ? s1_attribute[5:3] : s1_attribute[2:0];
    wire mix_bright = cfg[0] && s1_attribute[6];

    // The average of an RGB333 colour and a Spectrum colour (G R B) at level
    // 0xBF (5 of 7) or 0xFF (7), channel by channel, rounding down.
    function [8:0] mixed(input [8:0] rgb, input [2:0] colour, input bright);
        reg [2:0] level;
        reg [3:0] r, g, b;
        begin
            level = bright ? 3'd7 : 3'd5;
            r = rgb[8:6] + (colour[1] ? level : 3'd0);
            g = rgb[5:3] + (colour[2] ? level : 3'd0);
            b = rgb[2:0] + (colour[0] ? level : 3'd0);
            mixed = {r[3:1], g[3:1], b[3:1]};
        end
    endfunction

    wire show_background = background_present &&
        (render_dos ? index == 8'h00
                    : s1_background != 8'h00 &&
                      (index == 8'h00 || (index == 8'hff && bk_over_ff && s1_ink != 3'd7)));

    // Plane k is bit k of the index; the pixel is bit 7 - x mod 8 of its byte.
    wire [7:0] index;
    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : planes
            assign index[k] = s1_word[8 * k + s1_bit];
        end
    endgenerate
endmodule

`default_nettype wire
