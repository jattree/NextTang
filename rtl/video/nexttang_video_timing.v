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
    parameter integer V_BITS = 10
) (
    input  wire              pixel_clk,
    input  wire              reset,
    output reg               hsync,
    output reg               vsync,
    output reg               data_enable,
    output reg  [H_BITS-1:0] horizontal_position,
    output reg  [V_BITS-1:0] vertical_position
);
    localparam integer H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
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
        end else begin
            horizontal_position <= horizontal_counter;
            vertical_position <= vertical_counter;
            hsync <= horizontal_counter >= H_ACTIVE + H_FRONT &&
                     horizontal_counter < H_ACTIVE + H_FRONT + H_SYNC;
            vsync <= vertical_counter >= V_ACTIVE + V_FRONT &&
                     vertical_counter < V_ACTIVE + V_FRONT + V_SYNC;
            data_enable <= horizontal_counter < H_ACTIVE &&
                           vertical_counter < V_ACTIVE;

            if (horizontal_counter == H_TOTAL - 1) begin
                horizontal_counter <= 0;
                if (vertical_counter == V_TOTAL - 1)
                    vertical_counter <= 0;
                else
                    vertical_counter <= vertical_counter + 1'b1;
            end else begin
                horizontal_counter <= horizontal_counter + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
