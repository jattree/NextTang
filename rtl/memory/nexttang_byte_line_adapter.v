// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Convert one byte transaction into one 16-byte memory-line transaction.
// line_write_enable is active high: one bit enables the corresponding byte.
module nexttang_byte_line_adapter (
    input  wire         clock,
    input  wire         reset,

    input  wire         byte_request,
    output wire         byte_ready,
    input  wire         byte_write,
    input  wire [20:0]  byte_address,
    input  wire [7:0]   byte_write_data,
    output reg          byte_response_valid,
    output reg  [7:0]   byte_read_data,

    output reg          line_request,
    input  wire         line_ready,
    output reg          line_write,
    output reg  [16:0]  line_address,
    output reg  [127:0] line_write_data,
    output reg  [15:0]  line_write_enable,
    input  wire         line_response_valid,
    input  wire [127:0] line_read_data
);
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_ISSUE = 2'd1;
    localparam [1:0] STATE_RESPONSE = 2'd2;

    reg [1:0] state;
    reg [3:0] read_lane;

    assign byte_ready = state == STATE_IDLE;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            read_lane <= 0;
            byte_response_valid <= 1'b0;
            byte_read_data <= 0;
            line_request <= 1'b0;
            line_write <= 1'b0;
            line_address <= 0;
            line_write_data <= 0;
            line_write_enable <= 0;
        end else begin
            byte_response_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    line_request <= 1'b0;
                    if (byte_request) begin
                        line_write <= byte_write;
                        line_address <= byte_address[20:4];
                        read_lane <= byte_address[3:0];
                        line_write_data <= 128'b0;
                        line_write_data[byte_address[3:0] * 8 +: 8]
                            <= byte_write_data;
                        line_write_enable <= 16'b1 << byte_address[3:0];
                        line_request <= 1'b1;
                        state <= STATE_ISSUE;
                    end
                end

                STATE_ISSUE: begin
                    if (line_ready) begin
                        line_request <= 1'b0;
                        if (line_response_valid) begin
                            if (!line_write)
                                byte_read_data <=
                                    line_read_data[read_lane * 8 +: 8];
                            byte_response_valid <= 1'b1;
                            state <= STATE_IDLE;
                        end else begin
                            state <= STATE_RESPONSE;
                        end
                    end
                end

                STATE_RESPONSE: begin
                    if (line_response_valid) begin
                        if (!line_write)
                            byte_read_data <=
                                line_read_data[read_lane * 8 +: 8];
                        byte_response_valid <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    line_request <= 1'b0;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
