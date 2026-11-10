// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_video_timing #(
    parameter integer H_ACTIVE = 1280,
    parameter integer H_FRONT = 110,
    parameter integer H_SYNC = 40,
    parameter integer H_BACK = 220,
    parameter integer V_ACTIVE = 720,
    parameter integer V_FRONT = 5,
    parameter integer V_SYNC = 5,
    parameter integer V_BACK = 20,
    parameter integer H_BITS = 11,
    parameter integer V_BITS = 10,
    // A second horizontal front porch, used for the frames that start while
    // alt_select is high (720p60 beside 720p50: 110 beside 440). 0 keeps the
    // single fixed timing, and alt_select is then ignored.
    parameter integer H_FRONT_ALT = 0
) (
    input  wire              pixel_clk,
    input  wire              reset,
    input  wire              alt_select,
    output reg               alt_active = 1'b0,
    output reg               hsync,
    output reg               vsync,
    output reg               data_enable,
    output reg  [H_BITS-1:0] horizontal_position,
    output reg  [V_BITS-1:0] vertical_position
);
    localparam integer H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam integer H_TOTAL_ALT = H_ACTIVE + H_FRONT_ALT + H_SYNC + H_BACK;

    // The line's front porch and length for this frame.
    wire [H_BITS-1:0] h_front = alt_active ? H_FRONT_ALT[H_BITS-1:0] : H_FRONT[H_BITS-1:0];
    wire [H_BITS-1:0] h_last = alt_active ? H_TOTAL_ALT[H_BITS-1:0] - 1'b1
                                          : H_TOTAL[H_BITS-1:0] - 1'b1;
    localparam integer V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

    reg [H_BITS-1:0] horizontal_counter;
    reg [V_BITS-1:0] vertical_counter;

    always @(posedge pixel_clk) begin
        if (reset) begin
            horizontal_counter <= 0;
            vertical_counter <= 0;
            horizontal_position <= 0;
            vertical_position <= 0;
            hsync <= 0;
            vsync <= 0;
            data_enable <= 1'b1;
            alt_active <= 1'b0;
        end else begin
            horizontal_position <= horizontal_counter;
            vertical_position <= vertical_counter;
            hsync <= horizontal_counter >= H_ACTIVE + h_front &&
                     horizontal_counter < H_ACTIVE + h_front + H_SYNC;
            vsync <= vertical_counter >= V_ACTIVE + V_FRONT &&
                     vertical_counter < V_ACTIVE + V_FRONT + V_SYNC;
            data_enable <= horizontal_counter < H_ACTIVE &&
                           vertical_counter < V_ACTIVE;

            if (horizontal_counter == h_last) begin
                horizontal_counter <= 0;
                if (vertical_counter == V_TOTAL - 1) begin
                    vertical_counter <= 0;
                    alt_active <= H_FRONT_ALT != 0 && alt_select;
                end
                else begin
                    vertical_counter <= vertical_counter + 1'b1;
                end
            end else begin
                horizontal_counter <= horizontal_counter + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
