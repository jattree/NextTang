// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Direct 720p renderer for the eight live Spec256 graphical memory lanes.
//
// A graphical value of 0xFF marks a pixel the artist did not recolour. The
// ordinary Spectrum screen and its attribute colour show through there, so
// this module reports the value on `passthrough` and leaves the choice to the
// caller. GZX has no case for it and paints palette entry 255 instead, which
// is why unrecoloured text renders as a flat sentinel red.

`default_nettype none

module nexttang_spec256_display #(
    parameter integer SCALE = 3,
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer H_BITS = 11,
    parameter integer V_BITS = 10
) (
    input  wire                 pixel_clock,
    input  wire                 reset,
    input  wire [H_BITS-1:0]    horizontal_position,
    input  wire [V_BITS-1:0]    vertical_position,
    input  wire                 data_enable,
    output reg  [15:0]          memory_address,
    input  wire [63:0]          memory_data,

    // Optional 320x200 background, substituted where the paper is 0.  The
    // address is presented one pixel early so the byte arrives on the pixel it
    // belongs to, which keeps this module's output latency unchanged.
    output reg  [15:0]          background_address,
    input  wire [7:0]           background_data,
    input  wire                 background_valid,

    output wire [7:0]           palette_index,
    output wire                 passthrough
);
    localparam integer PICTURE_WIDTH = 256 * SCALE;
    localparam integer PICTURE_HEIGHT = 192 * SCALE;
    localparam integer LEFT = (H_ACTIVE - PICTURE_WIDTH) / 2;
    localparam integer TOP = (V_ACTIVE - PICTURE_HEIGHT) / 2;
    localparam integer CELL_CLOCKS = 8 * SCALE;
    localparam integer FETCH_START = LEFT - CELL_CLOCKS;

    // Spec256 backgrounds are 320x200 with the 256x192 paper centred, so a
    // paper pixel sits 32 columns and 4 lines into the image.
    localparam integer BACKGROUND_WIDTH = 320;
    localparam integer BACKGROUND_PAPER_X = (BACKGROUND_WIDTH - 256) / 2;
    localparam integer BACKGROUND_PAPER_Y = (200 - 192) / 2;

    wire in_picture = data_enable &&
                      horizontal_position >= LEFT &&
                      horizontal_position < LEFT + PICTURE_WIDTH &&
                      vertical_position >= TOP &&
                      vertical_position < TOP + PICTURE_HEIGHT;

    wire [V_BITS-1:0] picture_line = vertical_position - TOP[V_BITS-1:0];
    wire [7:0] source_y = picture_line / SCALE;
    wire fetch_active = horizontal_position >= FETCH_START &&
                        horizontal_position < LEFT + PICTURE_WIDTH - CELL_CLOCKS;
    wire [H_BITS-1:0] fetch_pixel =
        horizontal_position - FETCH_START[H_BITS-1:0];
    wire [4:0] fetch_cell = fetch_pixel / CELL_CLOCKS;
    wire [12:0] bitmap_offset =
        {source_y[7:6], source_y[2:0], source_y[5:3], fetch_cell};
    wire [15:0] requested_memory_address = {3'b010, bitmap_offset};

    wire [H_BITS-1:0] picture_pixel =
        horizontal_position - LEFT[H_BITS-1:0];
    wire [7:0] display_x = picture_pixel / SCALE;
    wire load_cell = in_picture && (picture_pixel % CELL_CLOCKS) == 0;

    // One pixel ahead.  The offset is combinational from the current position
    // and is then registered once, so the synchronous read returns it on the
    // next pixel.  The arithmetic wraps at a line start, which lands on
    // column 0 correctly.
    wire [H_BITS-1:0] lookahead_pixel = picture_pixel + 1'd1;
    wire [7:0] lookahead_x = lookahead_pixel / SCALE;

    // The row term costs a divide by SCALE and a multiply by 320, which does
    // not fit in a pixel clock alongside the rest of the address.  It changes
    // once per scanline, so it is registered; the one clock of lag is absorbed
    // by horizontal blanking long before the picture starts.
    reg [15:0] background_row_base = 16'b0;
    wire [15:0] background_offset =
        background_row_base + BACKGROUND_PAPER_X + lookahead_x;

    reg fetch_active_d1 = 1'b0;
    reg fetch_active_d2 = 1'b0;
    reg [63:0] lane_latch = 64'b0;
    reg [63:0] lane_shift = 64'b0;
    reg [7:0] previous_x = 8'b0;
    integer lane;

    always @(posedge pixel_clock) begin
        if (reset) begin
            memory_address <= 16'b0;
            background_address <= 16'b0;
            background_row_base <= 16'b0;
            fetch_active_d1 <= 1'b0;
            fetch_active_d2 <= 1'b0;
            lane_latch <= 64'b0;
            lane_shift <= 64'b0;
            previous_x <= 8'b0;
        end else begin
            // Register the display-side RAM address so the screen counters do
            // not drive every graphical-memory block combinationally.  The
            // RAM read is synchronous, so qualify its result two clocks after
            // the original request.
            memory_address <= requested_memory_address;
            background_row_base <=
                (BACKGROUND_PAPER_Y + source_y) * BACKGROUND_WIDTH;
            background_address <= background_offset;
            fetch_active_d1 <= fetch_active;
            fetch_active_d2 <= fetch_active_d1;
            if (fetch_active_d2)
                lane_latch <= memory_data;

            previous_x <= display_x;
            if (load_cell) begin
                lane_shift <= lane_latch;
            end else if (in_picture && display_x != previous_x) begin
                for (lane = 0; lane < 8; lane = lane + 1)
                    lane_shift[lane * 8 +: 8] <=
                        {lane_shift[lane * 8 +: 7], 1'b0};
            end
        end
    end

    wire [7:0] graphical_pixel = {
        lane_shift[63], lane_shift[55], lane_shift[47], lane_shift[39],
        lane_shift[31], lane_shift[23], lane_shift[15], lane_shift[7]
    };

    // The reference substitutes the background only where the assembled value
    // is zero, and uses any non-zero value directly.  0xFF is non-zero, so a
    // passthrough pixel is never a background pixel.
    wire background_pixel = background_valid && graphical_pixel == 8'h00;

    assign palette_index = !in_picture ? 8'h00 :
                           background_pixel ? background_data : graphical_pixel;
    assign passthrough = in_picture && graphical_pixel == 8'hFF;
endmodule

`default_nettype wire
