// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Types a fixed line into the machine by pressing keys the way a person does.
//
// The ROM scans the keyboard once per frame and wants a key held for several
// frames and then released before it accepts the next one, so this holds and
// releases rather than presenting a key for a single read. It waits before
// starting because the ROM spends its first second testing memory and ignores
// the keyboard until it reaches its main loop.
//
// This exists to prove the read path and the interpreter without a keyboard
// attached. A real keyboard drives the same matrix input.

`default_nettype none

module nexttang_key_sequencer #(
    parameter integer CLOCK_HZ = 3500000,
    parameter integer START_DELAY_MS = 3000,
    parameter integer HOLD_MS = 140,
    parameter integer GAP_MS = 140
) (
    input  wire        clock,
    input  wire        reset,
    output reg  [39:0] keys,
    output reg         finished
);
    localparam integer START_CYCLES = (CLOCK_HZ / 1000) * START_DELAY_MS;
    localparam integer HOLD_CYCLES  = (CLOCK_HZ / 1000) * HOLD_MS;
    localparam integer GAP_CYCLES   = (CLOCK_HZ / 1000) * GAP_MS;
    localparam integer STEPS = 12;

    // Each step is {symbol shift, row, column}. The keyword P at the start of a
    // line gives PRINT, and symbol shift with P gives a quote.
    //
    //   PRINT "NEXTTANG"
    function [6:0] step_key(input [3:0] index);
        case (index)
            4'd0:  step_key = {1'b0, 3'd5, 3'd0};   // P, which prints as PRINT
            4'd1:  step_key = {1'b1, 3'd5, 3'd0};   // symbol shift P, a quote
            4'd2:  step_key = {1'b0, 3'd7, 3'd3};   // N
            4'd3:  step_key = {1'b0, 3'd2, 3'd2};   // E
            4'd4:  step_key = {1'b0, 3'd0, 3'd2};   // X
            4'd5:  step_key = {1'b0, 3'd2, 3'd4};   // T
            4'd6:  step_key = {1'b0, 3'd2, 3'd4};   // T
            4'd7:  step_key = {1'b0, 3'd1, 3'd0};   // A
            4'd8:  step_key = {1'b0, 3'd7, 3'd3};   // N
            4'd9:  step_key = {1'b0, 3'd1, 3'd4};   // G
            4'd10: step_key = {1'b1, 3'd5, 3'd0};   // symbol shift P, a quote
            default: step_key = {1'b0, 3'd6, 3'd0}; // ENTER
        endcase
    endfunction

    localparam [1:0] WAITING = 2'd0, HOLDING = 2'd1, RELEASING = 2'd2, DONE = 2'd3;

    reg [1:0]  state = WAITING;
    reg [3:0]  step = 0;
    reg [26:0] timer = 0;

    wire [6:0] current = step_key(step);
    wire [2:0] row = current[5:3];
    wire [2:0] column = current[2:0];
    wire       symbol_shift = current[6];

    always @(posedge clock) begin
        if (reset) begin
            state <= WAITING;
            step <= 0;
            timer <= 0;
            keys <= 0;
            finished <= 0;
        end else begin
            case (state)
                WAITING: begin
                    keys <= 0;
                    if (timer == START_CYCLES - 1) begin
                        timer <= 0;
                        state <= HOLDING;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                HOLDING: begin
                    keys <= 0;
                    keys[row * 5 + column] <= 1'b1;
                    if (symbol_shift)
                        keys[7 * 5 + 1] <= 1'b1;    // symbol shift
                    if (timer == HOLD_CYCLES - 1) begin
                        timer <= 0;
                        state <= RELEASING;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                RELEASING: begin
                    keys <= 0;
                    if (timer == GAP_CYCLES - 1) begin
                        timer <= 0;
                        if (step == STEPS - 1) begin
                            state <= DONE;
                        end else begin
                            step <= step + 1'b1;
                            state <= HOLDING;
                        end
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                default: begin
                    keys <= 0;
                    finished <= 1'b1;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
