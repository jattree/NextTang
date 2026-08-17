// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_ddr_logo_video #(
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
    input  wire              pixel_clock,
    input  wire              reset,
    input  wire              completion_toggle,
    input  wire              completion_bank,
    output reg               reload_request_toggle,
    output reg               reload_request_bank,
    output wire              framebuffer_read_bank,
    output wire [13:0]       framebuffer_read_address,
    input  wire [7:0]        framebuffer_read_data,
    output reg               logo_available,
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
    reg active_bank;
    reg completion_seen;

    reg pipeline_logo_region;
    reg pipeline_active;
    reg pipeline_hsync;
    reg pipeline_vsync;
    reg [23:0] pipeline_background;
    reg [H_BITS-1:0] pipeline_horizontal_position;
    reg [V_BITS-1:0] pipeline_vertical_position;

    wire [H_BITS-1:0] logo_column_full = horizontal_counter - logo_left;
    wire [V_BITS-1:0] logo_row_full = vertical_counter - logo_top;
    wire [6:0] logo_column = logo_column_full[7:1];
    wire [6:0] logo_row = logo_row_full[7:1];
    wire logo_region = horizontal_counter >= logo_left &&
                       horizontal_counter < logo_left + LOGO_SIZE &&
                       vertical_counter >= logo_top &&
                       vertical_counter < logo_top + LOGO_SIZE;
    wire [23:0] background_colour =
        horizontal_counter < H_ACTIVE / 8 ? 24'hffffff :
        horizontal_counter < (H_ACTIVE * 2) / 8 ? 24'hffff00 :
        horizontal_counter < (H_ACTIVE * 3) / 8 ? 24'h00ffff :
        horizontal_counter < (H_ACTIVE * 4) / 8 ? 24'h00ff00 :
        horizontal_counter < (H_ACTIVE * 5) / 8 ? 24'hff00ff :
        horizontal_counter < (H_ACTIVE * 6) / 8 ? 24'hff0000 :
        horizontal_counter < (H_ACTIVE * 7) / 8 ? 24'h0000ff :
        24'h000000;

    assign framebuffer_read_bank = active_bank;
    assign framebuffer_read_address = {logo_row, logo_column};

    always @(posedge pixel_clock) begin
        if (reset) begin
            horizontal_counter <= 0;
            vertical_counter <= 0;
            logo_left <= LOGO_START_X;
            logo_top <= LOGO_START_Y;
            logo_moving_right <= 1'b1;
            logo_moving_down <= 1'b1;
            active_bank <= 0;
            completion_seen <= 0;
            reload_request_toggle <= 0;
            reload_request_bank <= 0;
            logo_available <= 0;
            pipeline_logo_region <= 0;
            pipeline_active <= 0;
            pipeline_hsync <= 0;
            pipeline_vsync <= 0;
            pipeline_background <= 0;
            pipeline_horizontal_position <= 0;
            pipeline_vertical_position <= 0;
            horizontal_position <= 0;
            vertical_position <= 0;
            hsync <= 0;
            vsync <= 0;
            data_enable <= 0;
            {red, green, blue} <= 24'h000000;
        end else begin
            horizontal_position <= pipeline_horizontal_position;
            vertical_position <= pipeline_vertical_position;
            hsync <= pipeline_hsync;
            vsync <= pipeline_vsync;
            data_enable <= pipeline_active;
            if (!pipeline_active)
                {red, green, blue} <= 24'h000000;
            else if (pipeline_logo_region && logo_available) begin
                red <= {framebuffer_read_data[7:5],
                        framebuffer_read_data[7:5],
                        framebuffer_read_data[7:6]};
                green <= {framebuffer_read_data[4:2],
                          framebuffer_read_data[4:2],
                          framebuffer_read_data[4:3]};
                blue <= {framebuffer_read_data[1:0],
                         framebuffer_read_data[1:0],
                         framebuffer_read_data[1:0],
                         framebuffer_read_data[1:0]};
            end else begin
                {red, green, blue} <= pipeline_background;
            end

            pipeline_horizontal_position <= horizontal_counter;
            pipeline_vertical_position <= vertical_counter;
            pipeline_hsync <= horizontal_counter >= H_ACTIVE + H_FRONT &&
                              horizontal_counter <
                                  H_ACTIVE + H_FRONT + H_SYNC;
            pipeline_vsync <= vertical_counter >= V_ACTIVE + V_FRONT &&
                              vertical_counter <
                                  V_ACTIVE + V_FRONT + V_SYNC;
            pipeline_active <= horizontal_counter < H_ACTIVE &&
                               vertical_counter < V_ACTIVE;
            pipeline_logo_region <= logo_region;
            pipeline_background <= background_colour;

            if (horizontal_counter == H_TOTAL - 1) begin
                horizontal_counter <= 0;
                if (vertical_counter == V_TOTAL - 1) begin
                    vertical_counter <= 0;
                    if (completion_toggle != completion_seen) begin
                        completion_seen <= completion_toggle;
                        active_bank <= completion_bank;
                        logo_available <= 1'b1;
                        reload_request_bank <= ~completion_bank;
                        reload_request_toggle <= ~reload_request_toggle;
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
