// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Press up to four Spectrum matrix keys using launch metadata received in a
// runtime Spec256 game pack.  Key values are row-major matrix indices 0..39.

`default_nettype none

module nexttang_spec256_runtime_key_sequencer #(
    parameter integer CLOCK_HZ = 3500000
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        start,
    input  wire [2:0]  key_count,
    input  wire [7:0]  key_0,
    input  wire [7:0]  key_1,
    input  wire [7:0]  key_2,
    input  wire [7:0]  key_3,
    input  wire [15:0] start_delay_ms,
    input  wire [15:0] hold_ms,
    input  wire [15:0] gap_ms,
    output reg  [39:0] keys,
    output reg         finished
);
    localparam integer CYCLES_PER_MS = CLOCK_HZ / 1000;
    localparam [2:0] STATE_IDLE  = 3'd0;
    localparam [2:0] STATE_DELAY = 3'd1;
    localparam [2:0] STATE_HOLD  = 3'd2;
    localparam [2:0] STATE_GAP   = 3'd3;
    localparam [2:0] STATE_DONE  = 3'd4;

    reg [2:0] state;
    reg [1:0] key_number;
    reg [15:0] milliseconds_left;
    reg [31:0] millisecond_divider;

    function [7:0] selected_key;
        input [1:0] number;
        begin
            case (number)
                0: selected_key = key_0;
                1: selected_key = key_1;
                2: selected_key = key_2;
                default: selected_key = key_3;
            endcase
        end
    endfunction

    function [39:0] key_mask;
        input [7:0] key_index;
        begin
            if (key_index < 40)
                key_mask = 40'b1 << key_index;
            else
                key_mask = 40'b0;
        end
    endfunction

    always @(posedge clock) begin
        if (reset) begin
            state <= STATE_IDLE;
            key_number <= 0;
            milliseconds_left <= 0;
            millisecond_divider <= 0;
            keys <= 0;
            finished <= 1'b0;
        end else begin
            if (millisecond_divider == CYCLES_PER_MS - 1)
                millisecond_divider <= 0;
            else
                millisecond_divider <= millisecond_divider + 1'b1;

            if (state == STATE_IDLE && start) begin
                key_number <= 0;
                if (key_count == 0) begin
                    state <= STATE_DONE;
                    finished <= 1'b1;
                end else if (start_delay_ms == 0) begin
                    keys <= key_mask(key_0);
                    milliseconds_left <= hold_ms;
                    state <= STATE_HOLD;
                end else begin
                    milliseconds_left <= start_delay_ms;
                    state <= STATE_DELAY;
                end
            end else if (millisecond_divider == CYCLES_PER_MS - 1) begin
                case (state)
                    STATE_DELAY: begin
                        if (milliseconds_left <= 1) begin
                            keys <= key_mask(selected_key(key_number));
                            milliseconds_left <= hold_ms;
                            state <= STATE_HOLD;
                        end else begin
                            milliseconds_left <= milliseconds_left - 1'b1;
                        end
                    end
                    STATE_HOLD: begin
                        if (milliseconds_left <= 1) begin
                            keys <= 0;
                            if (key_number + 1 >= key_count) begin
                                state <= STATE_DONE;
                                finished <= 1'b1;
                            end else begin
                                milliseconds_left <= gap_ms;
                                state <= STATE_GAP;
                            end
                        end else begin
                            milliseconds_left <= milliseconds_left - 1'b1;
                        end
                    end
                    STATE_GAP: begin
                        if (milliseconds_left <= 1) begin
                            key_number <= key_number + 1'b1;
                            keys <= key_mask(selected_key(key_number + 1'b1));
                            milliseconds_left <= hold_ms;
                            state <= STATE_HOLD;
                        end else begin
                            milliseconds_left <= milliseconds_left - 1'b1;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
