// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Turn zxula_timing's qualified 360x288 pixel stream into explicit frame-buffer
// coordinates.  The upstream timing block deliberately exposes ULA-relative
// counters rather than its raw raster counters, so deriving frame-buffer
// addresses from those counters would wrap inside the border.  This bridge
// instead counts the already-qualified contiguous pixel runs.

`default_nettype none

module nexttang_ula_capture #(
    parameter integer FRAME_WIDTH = 360,
    parameter integer FRAME_HEIGHT = 288,
    parameter integer PIXEL_BITS = 8
) (
    input  wire                              clock,
    input  wire                              reset,
    input  wire                              frame_sync,
    input  wire                              pixel_valid,
    input  wire [PIXEL_BITS-1:0]             pixel,
    output reg                               capture_frame_start,
    output reg                               capture_pixel_valid,
    output reg [$clog2(FRAME_WIDTH)-1:0]      capture_x,
    output reg [$clog2(FRAME_HEIGHT)-1:0]     capture_y,
    output reg [PIXEL_BITS-1:0]              capture_pixel,
    output reg                               protocol_error
);
    reg [$clog2(FRAME_WIDTH)-1:0] x;
    reg [$clog2(FRAME_HEIGHT)-1:0] y;
    reg armed;
    reg first_pixel_pending;
    reg was_valid;
    reg line_full;

    always @(posedge clock) begin
        if (reset) begin
            x <= 0;
            y <= 0;
            armed <= 1'b0;
            first_pixel_pending <= 1'b0;
            was_valid <= 1'b0;
            line_full <= 1'b0;
            capture_frame_start <= 1'b0;
            capture_pixel_valid <= 1'b0;
            capture_x <= 0;
            capture_y <= 0;
            capture_pixel <= 0;
            protocol_error <= 1'b0;
        end else begin
            capture_frame_start <= 1'b0;
            capture_pixel_valid <= 1'b0;

            if (frame_sync) begin
                if (was_valid)
                    protocol_error <= 1'b1;
                x <= 0;
                y <= 0;
                armed <= 1'b1;
                first_pixel_pending <= 1'b1;
                was_valid <= 1'b0;
                line_full <= 1'b0;
            end else if (pixel_valid) begin
                if (armed) begin
                    was_valid <= 1'b1;
                    if (!line_full) begin
                        capture_frame_start <= first_pixel_pending;
                        capture_pixel_valid <= 1'b1;
                        capture_x <= x;
                        capture_y <= y;
                        capture_pixel <= pixel;
                        first_pixel_pending <= 1'b0;

                        if (x == FRAME_WIDTH - 1) begin
                            x <= 0;
                            line_full <= 1'b1;
                        end else begin
                            x <= x + 1'b1;
                        end
                    end else begin
                        // More qualified pixels than fit in one source line.
                        protocol_error <= 1'b1;
                    end
                end else begin
                    // Reset may release in the middle of a raster. Ignore all
                    // qualified pixels until a complete frame boundary arms
                    // the bridge; they are not a malformed captured line.
                    was_valid <= 1'b0;
                end
            end else begin
                if (armed && was_valid) begin
                    if (!line_full) begin
                        // A qualified run ended before FRAME_WIDTH pixels.
                        protocol_error <= 1'b1;
                    end else if (y == FRAME_HEIGHT - 1) begin
                        armed <= 1'b0;
                    end else begin
                        y <= y + 1'b1;
                    end
                end
                x <= 0;
                was_valid <= 1'b0;
                line_full <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
