// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// One-shot diagnostic for the full-speed USB bring-up. A descriptor snapshot
// is latched in the USB clock domain and emitted without an unsafe wide CDC.
//
// Line format, 115200 8N1:
//
//     USB2 F1 S9295 0103010000040001

`default_nettype none

module nexttang_usb_snapshot_uart #(
    parameter integer CLOCK_HZ = 60000000,
    parameter integer BAUD_RATE = 115200
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        snapshot_valid,
    input  wire        port_two,
    input  wire        full_speed,
    input  wire [15:0] speed_sample,
    input  wire [63:0] snapshot,
    output reg         transmit
);
    localparam integer MESSAGE_BYTES = 32;

    reg [63:0] latched_snapshot = 0;
    reg [15:0] latched_speed_sample = 0;
    reg latched_port_two = 0;
    reg latched_full_speed = 0;
    reg pending = 0;

    function [7:0] hex_digit(input [3:0] value);
        hex_digit = (value < 10) ? ("0" + value) : ("a" + value - 10);
    endfunction

    wire [MESSAGE_BYTES*8-1:0] message = {
        "U", "S", "B", latched_port_two ? "2" : "1", " ",
        "F", latched_full_speed ? "1" : "0", " ", "S",
        hex_digit(latched_speed_sample[15:12]),
        hex_digit(latched_speed_sample[11:8]),
        hex_digit(latched_speed_sample[7:4]),
        hex_digit(latched_speed_sample[3:0]), " ",
        hex_digit(latched_snapshot[63:60]),
        hex_digit(latched_snapshot[59:56]),
        hex_digit(latched_snapshot[55:52]),
        hex_digit(latched_snapshot[51:48]),
        hex_digit(latched_snapshot[47:44]),
        hex_digit(latched_snapshot[43:40]),
        hex_digit(latched_snapshot[39:36]),
        hex_digit(latched_snapshot[35:32]),
        hex_digit(latched_snapshot[31:28]),
        hex_digit(latched_snapshot[27:24]),
        hex_digit(latched_snapshot[23:20]),
        hex_digit(latched_snapshot[19:16]),
        hex_digit(latched_snapshot[15:12]),
        hex_digit(latched_snapshot[11:8]),
        hex_digit(latched_snapshot[7:4]),
        hex_digit(latched_snapshot[3:0]),
        8'h0d, 8'h0a
    };

    reg [MESSAGE_BYTES*8-1:0] shift_message = 0;
    reg [7:0] bytes_left = 0;
    reg [3:0] bit_index = 0;
    reg [31:0] baud_accumulator = 0;
    reg [9:0] shifter = 10'h3ff;
    reg sending = 0;

    always @(posedge clock) begin
        if (reset) begin
            latched_snapshot <= 0;
            latched_speed_sample <= 0;
            latched_port_two <= 0;
            latched_full_speed <= 0;
            pending <= 0;
            transmit <= 1'b1;
            shift_message <= 0;
            bytes_left <= 0;
            bit_index <= 0;
            baud_accumulator <= 0;
            shifter <= 10'h3ff;
            sending <= 0;
        end else begin
            if (snapshot_valid) begin
                latched_snapshot <= snapshot;
                latched_speed_sample <= speed_sample;
                latched_port_two <= port_two;
                latched_full_speed <= full_speed;
                pending <= 1'b1;
            end

            if (!sending) begin
                transmit <= 1'b1;
                if (pending && !snapshot_valid) begin
                    pending <= 1'b0;
                    shift_message <= message << 8;
                    shifter <= {1'b1,
                                message[MESSAGE_BYTES*8-1 -: 8], 1'b0};
                    bytes_left <= MESSAGE_BYTES - 1;
                    bit_index <= 0;
                    baud_accumulator <= 0;
                    sending <= 1'b1;
                end
            end else begin
                baud_accumulator <= baud_accumulator + BAUD_RATE;
                if (baud_accumulator + BAUD_RATE >= CLOCK_HZ) begin
                    baud_accumulator <= baud_accumulator + BAUD_RATE - CLOCK_HZ;
                    transmit <= shifter[0];
                    shifter <= {1'b1, shifter[9:1]};
                    if (bit_index == 9) begin
                        bit_index <= 0;
                        if (bytes_left == 0) begin
                            sending <= 1'b0;
                        end else begin
                            shifter <= {
                                1'b1,
                                shift_message[MESSAGE_BYTES*8-1 -: 8],
                                1'b0
                            };
                            shift_message <= shift_message << 8;
                            bytes_left <= bytes_left - 1'b1;
                        end
                    end else begin
                        bit_index <= bit_index + 1'b1;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
