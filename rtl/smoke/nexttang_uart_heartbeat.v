// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_uart_heartbeat #(
    parameter integer CLOCK_HZ = 27000000,
    parameter integer BAUD_RATE = 2000000,
    parameter integer GAP_CLOCKS = 2700000
) (
    input  wire clock,
    input  wire reset,
    output reg  transmit
);
    localparam integer MESSAGE_LENGTH = 21;

    reg [7:0] message_character;
    reg [9:0] frame;
    reg [7:0] message_index;
    reg [3:0] bit_index;
    reg [31:0] baud_accumulator;
    reg [31:0] gap_count;
    reg busy;

    always @* begin
        case (message_index)
            0: message_character = "N";
            1: message_character = "E";
            2: message_character = "X";
            3: message_character = "T";
            4: message_character = "T";
            5: message_character = "A";
            6: message_character = "N";
            7: message_character = "G";
            8: message_character = " ";
            9: message_character = "1";
            10: message_character = "3";
            11: message_character = "8";
            12: message_character = "K";
            13: message_character = " ";
            14: message_character = "S";
            15: message_character = "M";
            16: message_character = "O";
            17: message_character = "K";
            18: message_character = "E";
            19: message_character = 8'h0d;
            default: message_character = 8'h0a;
        endcase
    end

    always @(posedge clock) begin
        if (reset) begin
            transmit <= 1'b1;
            frame <= 10'h3ff;
            message_index <= 0;
            bit_index <= 0;
            baud_accumulator <= 0;
            gap_count <= 0;
            busy <= 1'b0;
        end else if (busy) begin
            if (baud_accumulator >= CLOCK_HZ - BAUD_RATE) begin
                baud_accumulator <= baud_accumulator + BAUD_RATE - CLOCK_HZ;
                if (bit_index == 9) begin
                    transmit <= 1'b1;
                    busy <= 1'b0;
                    if (message_index == MESSAGE_LENGTH - 1) begin
                        message_index <= 0;
                        gap_count <= GAP_CLOCKS;
                    end else begin
                        message_index <= message_index + 1'b1;
                    end
                end else begin
                    bit_index <= bit_index + 1'b1;
                    transmit <= frame[bit_index + 1'b1];
                end
            end else begin
                baud_accumulator <= baud_accumulator + BAUD_RATE;
            end
        end else if (gap_count != 0) begin
            gap_count <= gap_count - 1'b1;
        end else begin
            frame <= {1'b1, message_character, 1'b0};
            transmit <= 1'b0;
            bit_index <= 0;
            baud_accumulator <= 0;
            busy <= 1'b1;
        end
    end
endmodule

`default_nettype wire
