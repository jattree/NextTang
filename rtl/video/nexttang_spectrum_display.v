// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Renders a ZX Spectrum display from screen memory onto a larger raster.
//
// The Spectrum's 256x192 bitmap is scaled by an integer factor and centred,
// which leaves a border around it. That is what the machine looks like, and an
// integer scale avoids resampling artefacts entirely: every source pixel
// becomes an exact square block.
//
// Screen memory is scattered rather than linear. The address of the byte
// holding pixel row y is built from three separate fields of y:
//
//   offset = ((y & 0xc0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2) | (x >> 3)
//
// Colour comes from a separate attribute byte per 8x8 cell, holding an ink and
// a paper colour, a brightness bit and a flash bit. Flash swaps ink and paper
// twice a second, which the original hardware derived from the frame counter.
//
// Reads are pipelined: the byte and attribute for a cell are fetched while the
// previous cell is still being displayed, so memory sees one access per eight
// output pixels rather than one per pixel.

`default_nettype none

module nexttang_spectrum_display #(
    parameter integer SCALE = 3,          // integer pixels per source pixel
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer H_BITS = 11,
    parameter integer V_BITS = 10
) (
    input  wire                pixel_clk,
    input  wire                reset,
    input  wire [H_BITS-1:0]   horizontal_position,
    input  wire [V_BITS-1:0]   vertical_position,
    input  wire                data_enable,
    input  wire [2:0]          border_colour,
    input  wire                flash_phase,

    // Port B of the shared screen memory, 0x0000 to 0x1AFF of the 0x4000 page.
    output wire [12:0]         screen_address,
    input  wire [7:0]          screen_data,

    output reg  [7:0]          red,
    output reg  [7:0]          green,
    output reg  [7:0]          blue
);
    localparam integer PICTURE_WIDTH  = 256 * SCALE;
    localparam integer PICTURE_HEIGHT = 192 * SCALE;
    localparam integer LEFT = (H_ACTIVE - PICTURE_WIDTH) / 2;
    localparam integer TOP  = (V_ACTIVE - PICTURE_HEIGHT) / 2;

    wire in_picture = data_enable &&
                      horizontal_position >= LEFT &&
                      horizontal_position <  LEFT + PICTURE_WIDTH &&
                      vertical_position   >= TOP &&
                      vertical_position   <  TOP + PICTURE_HEIGHT;

    // Source coordinates are derived from the raster position rather than
    // counted. Counters carry state that only becomes correct after sweeping a
    // whole frame from the top, which makes the renderer depend on history it
    // does not need and cannot be tested at a single position. Dividing by a
    // constant synthesises to a multiply and shift.
    localparam integer CELL_CLOCKS = 8 * SCALE;
    localparam integer FETCH_START = LEFT - CELL_CLOCKS;

    wire [V_BITS-1:0] picture_line = vertical_position - TOP[V_BITS-1:0];
    wire [7:0] source_y = picture_line / SCALE;

    // The fetch runs one character cell ahead of the display, so the first
    // cell of a line is already in the latch when the picture starts.
    wire fetch_active = horizontal_position >= FETCH_START &&
                        horizontal_position <  LEFT + PICTURE_WIDTH - CELL_CLOCKS;
    wire [H_BITS-1:0] fetch_pixel = horizontal_position - FETCH_START[H_BITS-1:0];
    wire [4:0] fetch_cell = fetch_pixel / CELL_CLOCKS;
    wire fetch_attribute = fetch_pixel[0];

    wire [H_BITS-1:0] picture_pixel = horizontal_position - LEFT[H_BITS-1:0];
    wire [7:0] display_x = picture_pixel / SCALE;
    wire load_cell = in_picture && (picture_pixel % (8 * SCALE)) == 0;

    wire [12:0] bitmap_address =
        {source_y[7:6], source_y[2:0], source_y[5:3], fetch_cell};
    wire [12:0] attribute_address =
        13'h1800 + {source_y[7:3], fetch_cell};

    assign screen_address = fetch_attribute ? attribute_address : bitmap_address;

    reg [7:0] bitmap_latch;
    reg [7:0] attribute_latch;
    reg [7:0] bitmap_shift;
    reg [7:0] attribute_active;
    reg [H_BITS-1:0] previous_pixel;

    // Screen memory answers a cycle after the address is presented, so the byte
    // arriving now belongs to the previous cycle's fetch. Routing it by the
    // current phase puts the bitmap in the attribute latch and the attribute in
    // the bitmap latch, which still draws colour and so looks like a picture
    // until you compare it against what was written.
    reg fetched_attribute;
    reg fetched_active;

    always @(posedge pixel_clk) begin
        if (reset) begin
            fetched_attribute <= 0;
            fetched_active <= 0;
        end else begin
            fetched_attribute <= fetch_attribute;
            fetched_active <= fetch_active;
        end
    end

    always @(posedge pixel_clk) begin
        if (reset) begin
            bitmap_latch <= 0;
            attribute_latch <= 0;
            bitmap_shift <= 0;
            attribute_active <= 0;
            previous_pixel <= 0;
        end else begin
            if (fetched_active) begin
                if (fetched_attribute)
                    attribute_latch <= screen_data;
                else
                    bitmap_latch <= screen_data;
            end

            previous_pixel <= picture_pixel;
            if (load_cell) begin
                bitmap_shift <= bitmap_latch;
                attribute_active <= attribute_latch;
            end else if (in_picture && display_x != previous_pixel / SCALE) begin
                bitmap_shift <= {bitmap_shift[6:0], 1'b0};
            end
        end
    end

    // Attribute byte: FLASH BRIGHT PAPER[2:0] INK[2:0]
    wire        flash  = attribute_active[7];
    wire        bright = attribute_active[6];
    wire [2:0]  paper  = attribute_active[5:3];
    wire [2:0]  ink    = attribute_active[2:0];
    wire        pixel_set = bitmap_shift[7] ^ (flash && flash_phase);
    wire [2:0]  colour = in_picture ? (pixel_set ? ink : paper) : border_colour;
    wire        level  = in_picture ? bright : 1'b0;

    // Spectrum colours are one bit per channel plus a brightness level.
    wire [7:0] intensity = level ? 8'hff : 8'hd7;

    always @(posedge pixel_clk) begin
        if (reset) begin
            red <= 0;
            green <= 0;
            blue <= 0;
        end else if (!data_enable) begin
            red <= 0;
            green <= 0;
            blue <= 0;
        end else begin
            red   <= colour[1] ? intensity : 8'h00;
            green <= colour[2] ? intensity : 8'h00;
            blue  <= colour[0] ? intensity : 8'h00;
        end
    end
endmodule

`default_nettype wire
