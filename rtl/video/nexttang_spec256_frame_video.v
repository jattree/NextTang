// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Displays one RGB332 Spec256 paper at an integer scale after DDR3 has filled
// the selected framebuffer bank.
module nexttang_spec256_frame_video #(
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
    parameter integer FRAME_WIDTH = 256,
    parameter integer FRAME_HEIGHT = 192,
    parameter integer FRAME_X_BITS = 8,
    parameter integer FRAME_Y_BITS = 8,
    parameter integer SCALE_SHIFT = 1
) (
    input  wire              pixel_clock,
    input  wire              reset,
    input  wire              completion_toggle,
    input  wire              completion_bank,
    output wire              reload_request_toggle,
    output wire              reload_request_bank,
    output wire              framebuffer_read_bank,
    output wire [FRAME_X_BITS+FRAME_Y_BITS-1:0]
                             framebuffer_read_address,
    input  wire [7:0]        framebuffer_read_data,
    output reg               frame_available,
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
    localparam integer DISPLAY_WIDTH = FRAME_WIDTH << SCALE_SHIFT;
    localparam integer DISPLAY_HEIGHT = FRAME_HEIGHT << SCALE_SHIFT;
    localparam integer FRAME_LEFT = (H_ACTIVE - DISPLAY_WIDTH) / 2;
    localparam integer FRAME_TOP = (V_ACTIVE - DISPLAY_HEIGHT) / 2;

    reg [H_BITS-1:0] horizontal_counter;
    reg [V_BITS-1:0] vertical_counter;
    reg active_bank;
    reg completion_seen;
    reg pipeline_frame_region;
    reg pipeline_active;
    reg pipeline_hsync;
    reg pipeline_vsync;
    reg [H_BITS-1:0] pipeline_horizontal_position;
    reg [V_BITS-1:0] pipeline_vertical_position;

    wire [H_BITS-1:0] frame_column_full = horizontal_counter - FRAME_LEFT;
    wire [V_BITS-1:0] frame_row_full = vertical_counter - FRAME_TOP;
    wire [FRAME_X_BITS-1:0] frame_column =
        frame_column_full >> SCALE_SHIFT;
    wire [FRAME_Y_BITS-1:0] frame_row = frame_row_full >> SCALE_SHIFT;
    wire frame_region = horizontal_counter >= FRAME_LEFT &&
                        horizontal_counter < FRAME_LEFT + DISPLAY_WIDTH &&
                        vertical_counter >= FRAME_TOP &&
                        vertical_counter < FRAME_TOP + DISPLAY_HEIGHT;

    assign reload_request_toggle = 1'b0;
    assign reload_request_bank = 1'b0;
    assign framebuffer_read_bank = active_bank;
    assign framebuffer_read_address = {frame_row, frame_column};

    always @(posedge pixel_clock) begin
        if (reset) begin
            horizontal_counter <= 0;
            vertical_counter <= 0;
            active_bank <= 0;
            completion_seen <= 0;
            frame_available <= 0;
            pipeline_frame_region <= 0;
            pipeline_active <= 0;
            pipeline_hsync <= 0;
            pipeline_vsync <= 0;
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
            else if (pipeline_frame_region && frame_available) begin
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
                {red, green, blue} <= 24'h101018;
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
            pipeline_frame_region <= frame_region;

            if (horizontal_counter == H_TOTAL - 1) begin
                horizontal_counter <= 0;
                if (vertical_counter == V_TOTAL - 1) begin
                    vertical_counter <= 0;
                    if (completion_toggle != completion_seen) begin
                        completion_seen <= completion_toggle;
                        active_bank <= completion_bank;
                        frame_available <= 1'b1;
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
