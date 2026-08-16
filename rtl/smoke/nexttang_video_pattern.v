// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_video_pattern #(
    parameter LOGO_FILE = "rtl/smoke/nexttang_logo_128x128_rgb332.mem",
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
    output reg  [7:0]        red,
    output reg  [7:0]        green,
    output reg  [7:0]        blue,
    output reg               hsync,
    output reg               vsync,
    output reg               data_enable,
    output reg  [H_BITS-1:0] horizontal_position,
    output reg  [V_BITS-1:0] vertical_position
);
    localparam integer H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam integer V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;
    localparam integer LOGO_SIZE = 256;
    localparam [H_BITS-1:0] LOGO_START_X = (H_ACTIVE - LOGO_SIZE) / 2;
    localparam [V_BITS-1:0] LOGO_START_Y = (V_ACTIVE - LOGO_SIZE) / 2;
    localparam [H_BITS-1:0] LOGO_MAX_X = H_ACTIVE - LOGO_SIZE - 8;
    localparam [V_BITS-1:0] LOGO_MAX_Y = V_ACTIVE - LOGO_SIZE - 8;

    reg [H_BITS-1:0] horizontal_counter;
    reg [V_BITS-1:0] vertical_counter;
    reg [H_BITS-1:0] logo_left;
    reg [V_BITS-1:0] logo_top;
    reg logo_moving_right;
    reg logo_moving_down;

    wire [H_BITS-1:0] logo_column_full = horizontal_counter - logo_left;
    wire [V_BITS-1:0] logo_row_full = vertical_counter - logo_top;
    wire [6:0] logo_column = logo_column_full[7:1];
    wire [6:0] logo_row = logo_row_full[7:1];
    wire [13:0] logo_address = {logo_row, logo_column};
    wire [7:0] logo_rgb332;
    wire logo_region = H_ACTIVE >= LOGO_SIZE + 16 &&
                       V_ACTIVE >= LOGO_SIZE + 16 &&
                       horizontal_counter >= logo_left &&
                       horizontal_counter < logo_left + LOGO_SIZE &&
                       vertical_counter >= logo_top &&
                       vertical_counter < logo_top + LOGO_SIZE;

    nexttang_logo_rom #(.INITIALISATION_FILE(LOGO_FILE)) logo (
        .address(logo_address),
        .rgb332(logo_rgb332)
    );

    always @(posedge pixel_clk) begin
        if (reset) begin
            horizontal_counter <= 0;
            vertical_counter <= 0;
            logo_left <= LOGO_START_X;
            logo_top <= LOGO_START_Y;
            logo_moving_right <= 1'b1;
            logo_moving_down <= 1'b1;
            horizontal_position <= 0;
            vertical_position <= 0;
            hsync <= 0;
            vsync <= 0;
            data_enable <= 1'b1;
            {red, green, blue} <= 24'hffffff;
        end else begin
            horizontal_position <= horizontal_counter;
            vertical_position <= vertical_counter;
            hsync <= horizontal_counter >= H_ACTIVE + H_FRONT &&
                     horizontal_counter < H_ACTIVE + H_FRONT + H_SYNC;
            vsync <= vertical_counter >= V_ACTIVE + V_FRONT &&
                     vertical_counter < V_ACTIVE + V_FRONT + V_SYNC;
            data_enable <= horizontal_counter < H_ACTIVE &&
                           vertical_counter < V_ACTIVE;

            if (horizontal_counter >= H_ACTIVE || vertical_counter >= V_ACTIVE)
                {red, green, blue} <= 24'h000000;
            else if (logo_region) begin
                red <= {logo_rgb332[7:5], logo_rgb332[7:5], logo_rgb332[7:6]};
                green <= {logo_rgb332[4:2], logo_rgb332[4:2], logo_rgb332[4:3]};
                blue <= {logo_rgb332[1:0], logo_rgb332[1:0],
                         logo_rgb332[1:0], logo_rgb332[1:0]};
            end else if (horizontal_counter < H_ACTIVE / 8)
                {red, green, blue} <= 24'hffffff;
            else if (horizontal_counter < (H_ACTIVE * 2) / 8)
                {red, green, blue} <= 24'hffff00;
            else if (horizontal_counter < (H_ACTIVE * 3) / 8)
                {red, green, blue} <= 24'h00ffff;
            else if (horizontal_counter < (H_ACTIVE * 4) / 8)
                {red, green, blue} <= 24'h00ff00;
            else if (horizontal_counter < (H_ACTIVE * 5) / 8)
                {red, green, blue} <= 24'hff00ff;
            else if (horizontal_counter < (H_ACTIVE * 6) / 8)
                {red, green, blue} <= 24'hff0000;
            else if (horizontal_counter < (H_ACTIVE * 7) / 8)
                {red, green, blue} <= 24'h0000ff;
            else
                {red, green, blue} <= 24'h000000;

            if (horizontal_counter == H_TOTAL - 1) begin
                horizontal_counter <= 0;
                if (vertical_counter == V_TOTAL - 1) begin
                    vertical_counter <= 0;
                    if (H_ACTIVE >= LOGO_SIZE + 16) begin
                        if (logo_left <= 8) begin
                            logo_left <= logo_left + 1'b1;
                            logo_moving_right <= 1'b1;
                        end else if (logo_left >= LOGO_MAX_X) begin
                            logo_left <= logo_left - 1'b1;
                            logo_moving_right <= 1'b0;
                        end else if (logo_moving_right) begin
                            logo_left <= logo_left + 1'b1;
                        end else begin
                            logo_left <= logo_left - 1'b1;
                        end
                    end
                    if (V_ACTIVE >= LOGO_SIZE + 16) begin
                        if (logo_top <= 8) begin
                            logo_top <= logo_top + 1'b1;
                            logo_moving_down <= 1'b1;
                        end else if (logo_top >= LOGO_MAX_Y) begin
                            logo_top <= logo_top - 1'b1;
                            logo_moving_down <= 1'b0;
                        end else if (logo_moving_down) begin
                            logo_top <= logo_top + 1'b1;
                        end else begin
                            logo_top <= logo_top - 1'b1;
                        end
                    end
                end else begin
                    vertical_counter <= vertical_counter + 1'b1;
                end
            end else begin
                horizontal_counter <= horizontal_counter + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
