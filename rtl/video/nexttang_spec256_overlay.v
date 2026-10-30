// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Spec256's colour picture, laid over the Next core's captured raster.
//
// The core's picture is captured at 7 MHz as a 360 x 288 window
// (nexttang_ula_capture), the Spectrum's 256 x 192 paper at (52, 48). For
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
// With render_dos (the .256's RUL1 flag for Spec256 DOS v1.2 games) indices
// 0xC0 to 0xFF take the cell's attribute ink instead: palette entry
// 11 iii xxx, iii the ink and xxx the index's low bits, so a game's text
// keeps the colours its attributes give it. 0xFF is then such an entry too,
// not the core's pixel. The ink comes from a copy of the attributes
// (bank 5, 0x1800 to 0x1AFF), kept from the core's writes to bank 5.
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

    // Bank 5 writes, on clock_28, as the core's bank 5 RAM takes them.
    input  wire        bank5_write,
    input  wire [13:0] bank5_address,
    input  wire [7:0]  bank5_data
);
    localparam [8:0] PAPER_X = 9'd52;
    localparam [8:0] PAPER_Y = 9'd48;

    wire [8:0] paper_x = capture_x - PAPER_X;
    wire [8:0] paper_y = capture_y - PAPER_Y;
    wire in_paper = capture_x >= PAPER_X && capture_x < PAPER_X + 9'd256 &&
                    capture_y >= PAPER_Y && capture_y < PAPER_Y + 9'd192;

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

    // Stage 1: the pixel and its plane word.
    reg        s1_frame_start, s1_valid, s1_paper;
    reg [8:0]  s1_x, s1_y, s1_pixel;
    reg [2:0]  s1_bit;
    reg [63:0] s1_word;
    reg [2:0]  s1_ink;

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

            frame_start <= s1_frame_start;
            pixel_valid <= s1_valid;
            x <= s1_x;
            y <= s1_y;
            if (!s1_paper || (!render_dos && index == 8'hff))
                pixel <= s1_pixel;
            else if (render_dos && index[7:6] == 2'b11)
                pixel <= palette[{2'b11, s1_ink, index[2:0]}];
            else
                pixel <= palette[index];
        end
    end

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
