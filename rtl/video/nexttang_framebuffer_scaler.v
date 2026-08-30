// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Frame-safe nearest-neighbour scan conversion between unrelated clocks.
//
// The source owns one of three frame banks, the HDMI side owns another, and a
// completed frame may wait in the third.  A bank changes owner only through the
// publish/acknowledge toggle handshake, and the HDMI side changes banks only at
// an output frame boundary.  This prevents both clock-domain sampling and the
// mid-frame bank swaps that show up as tearing.

`default_nettype none

module nexttang_framebuffer_scaler #(
    // zxula_timing's 48K/50 Hz raster is 448x312.  Its HDMI-qualified active
    // payload is 360x288, which doubles exactly to 720x576 inside 720p.
    parameter integer SOURCE_WIDTH = 360,
    parameter integer SOURCE_HEIGHT = 288,
    parameter integer SCALE = 2,
    parameter integer OUTPUT_WIDTH = 1280,
    parameter integer OUTPUT_HEIGHT = 720,
    parameter integer PIXEL_BITS = 8
) (
    input  wire                              source_clock,
    input  wire                              source_reset,
    input  wire                              source_frame_start,
    input  wire                              source_pixel_valid,
    input  wire [$clog2(SOURCE_WIDTH)-1:0]   source_x,
    input  wire [$clog2(SOURCE_HEIGHT)-1:0]  source_y,
    input  wire [PIXEL_BITS-1:0]             source_pixel,
    output reg                               source_overrun,

    input  wire                              output_clock,
    input  wire                              output_reset,
    input  wire                              output_frame_start,
    input  wire                              output_hsync,
    input  wire                              output_vsync,
    input  wire                              output_data_enable,
    input  wire [$clog2(OUTPUT_WIDTH)-1:0]   output_x,
    input  wire [$clog2(OUTPUT_HEIGHT)-1:0]  output_y,
    output reg                               scaled_hsync,
    output reg                               scaled_vsync,
    output reg                               scaled_data_enable,
    output reg  [PIXEL_BITS-1:0]             scaled_pixel,
    output reg                               output_frame_valid
);
    localparam integer SOURCE_PIXELS = SOURCE_WIDTH * SOURCE_HEIGHT;
    localparam integer STORAGE_PIXELS = SOURCE_PIXELS * 3;
    localparam integer ADDRESS_BITS = $clog2(STORAGE_PIXELS);
    localparam integer SCALED_WIDTH = SOURCE_WIDTH * SCALE;
    localparam integer SCALED_HEIGHT = SOURCE_HEIGHT * SCALE;
    localparam integer LEFT = (OUTPUT_WIDTH - SCALED_WIDTH) / 2;
    localparam integer TOP = (OUTPUT_HEIGHT - SCALED_HEIGHT) / 2;

    initial begin
        if (SCALE < 1)
            $error("nexttang_framebuffer_scaler: SCALE must be positive");
        if (SCALED_WIDTH > OUTPUT_WIDTH || SCALED_HEIGHT > OUTPUT_HEIGHT)
            $error("nexttang_framebuffer_scaler: scaled raster does not fit output");
    end

    reg [PIXEL_BITS-1:0] frame_memory [0:STORAGE_PIXELS-1];

    // --------------------------------------------------------------- producer
    reg [1:0] write_bank;
    reg [1:0] published_bank;
    reg       publish_toggle;
    reg       capture_active;

    reg       acknowledge_meta;
    reg       acknowledge_sync;
    reg [1:0] read_bank_meta;
    reg [1:0] read_bank_sync;

    wire [ADDRESS_BITS+1:0] source_address_wide =
        write_bank * SOURCE_PIXELS + source_y * SOURCE_WIDTH + source_x;
    wire [ADDRESS_BITS-1:0] source_address =
        source_address_wide[ADDRESS_BITS-1:0];
    wire source_last_pixel = source_x == SOURCE_WIDTH - 1 &&
                             source_y == SOURCE_HEIGHT - 1;

    function automatic [1:0] remaining_bank;
        input [1:0] first;
        input [1:0] second;
        begin
            remaining_bank = 2'd3 - first - second;
        end
    endfunction

    always @(posedge source_clock) begin
        if (source_reset) begin
            acknowledge_meta <= 1'b0;
            acknowledge_sync <= 1'b0;
            read_bank_meta <= 2'd0;
            read_bank_sync <= 2'd0;
        end else begin
            acknowledge_meta <= acknowledge_toggle;
            acknowledge_sync <= acknowledge_meta;
            read_bank_meta <= read_bank;
            read_bank_sync <= read_bank_meta;
        end
    end

    always @(posedge source_clock) begin
        if (source_reset) begin
            write_bank <= 2'd1;
            published_bank <= 2'd1;
            publish_toggle <= 1'b0;
            capture_active <= 1'b0;
            source_overrun <= 1'b0;
        end else begin
            if (source_frame_start)
                capture_active <= 1'b1;

            if (source_pixel_valid && (capture_active || source_frame_start)) begin
                frame_memory[source_address] <= source_pixel;

                if (source_last_pixel) begin
                    capture_active <= 1'b0;
                    if (acknowledge_sync == publish_toggle &&
                            read_bank_sync != write_bank) begin
                        published_bank <= write_bank;
                        publish_toggle <= !publish_toggle;
                        write_bank <= remaining_bank(write_bank, read_bank_sync);
                    end else begin
                        // The HDMI side did not consume the previous publication
                        // within one source frame.  Drop this completed frame and
                        // reuse its bank; never write into the reader's bank.
                        source_overrun <= 1'b1;
                    end
                end
            end
        end
    end

    // --------------------------------------------------------------- consumer
    reg       publish_meta;
    reg       publish_sync;
    reg [1:0] published_bank_meta;
    reg [1:0] published_bank_sync;
    reg [1:0] read_bank;
    reg       acknowledge_toggle;

    wire inside_picture = output_data_enable &&
                          output_x >= LEFT && output_x < LEFT + SCALED_WIDTH &&
                          output_y >= TOP && output_y < TOP + SCALED_HEIGHT;
    wire [30:0] mapped_x_calculation =
        (output_x - LEFT) / SCALE;
    wire [30:0] mapped_y_calculation =
        (output_y - TOP) / SCALE;
    wire [$clog2(OUTPUT_WIDTH)-1:0] mapped_x_wide =
        mapped_x_calculation[$clog2(OUTPUT_WIDTH)-1:0];
    wire [$clog2(OUTPUT_HEIGHT)-1:0] mapped_y_wide =
        mapped_y_calculation[$clog2(OUTPUT_HEIGHT)-1:0];
    wire [$clog2(SOURCE_WIDTH)-1:0] mapped_x =
        mapped_x_wide[$clog2(SOURCE_WIDTH)-1:0];
    wire [$clog2(SOURCE_HEIGHT)-1:0] mapped_y =
        mapped_y_wide[$clog2(SOURCE_HEIGHT)-1:0];
    wire [ADDRESS_BITS+1:0] output_address_wide =
        read_bank * SOURCE_PIXELS + mapped_y * SOURCE_WIDTH + mapped_x;
    wire [ADDRESS_BITS-1:0] output_address =
        output_address_wide[ADDRESS_BITS-1:0];
    // Break coordinate multiplication before the BSRAM address register.  At
    // 74.25 MHz the direct output_y*360 path is placement-sensitive once the
    // full loader is present.  Delay timing qualification by the same stage.
    reg [ADDRESS_BITS-1:0] output_address_q;
    reg inside_picture_q,output_hsync_q,output_vsync_q,output_data_enable_q;

    always @(posedge output_clock) begin
        if (output_reset) begin
            publish_meta <= 1'b0;
            publish_sync <= 1'b0;
            published_bank_meta <= 2'd1;
            published_bank_sync <= 2'd1;
        end else begin
            publish_meta <= publish_toggle;
            publish_sync <= publish_meta;
            published_bank_meta <= published_bank;
            published_bank_sync <= published_bank_meta;
        end
    end

    always @(posedge output_clock) begin
        if (output_reset) begin
            read_bank <= 2'd0;
            acknowledge_toggle <= 1'b0;
            output_frame_valid <= 1'b0;
            scaled_hsync <= 1'b0;
            scaled_vsync <= 1'b0;
            scaled_data_enable <= 1'b0;
            scaled_pixel <= {PIXEL_BITS{1'b0}};
            output_address_q <= {ADDRESS_BITS{1'b0}};
            inside_picture_q <= 1'b0;output_hsync_q <= 1'b0;
            output_vsync_q <= 1'b0;output_data_enable_q <= 1'b0;
        end else begin
            if (output_frame_start && publish_sync != acknowledge_toggle) begin
                read_bank <= published_bank_sync;
                acknowledge_toggle <= publish_sync;
                output_frame_valid <= 1'b1;
            end

            output_address_q <= output_address;inside_picture_q <= inside_picture;
            output_hsync_q <= output_hsync;output_vsync_q <= output_vsync;
            output_data_enable_q <= output_data_enable;
            scaled_hsync <= output_hsync_q;
            scaled_vsync <= output_vsync_q;
            scaled_data_enable <= output_data_enable_q;
            if (inside_picture_q && output_frame_valid)
                scaled_pixel <= frame_memory[output_address_q];
            else
                scaled_pixel <= {PIXEL_BITS{1'b0}};
        end
    end
endmodule

`default_nettype wire
