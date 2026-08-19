// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Types LOAD "" and then releases the keyboard. The tape player starts only
// after finished asserts, so its pilot cannot run past while the ROM boots.
//
// The two quotes are the same key twice. The ROM only frees a key's slot five
// keyboard scans after release, so the gap has to outlast five scans or the
// second press reads as the first one still held and one quote is lost. Scans
// happen on the frame interrupt, and a machine slowed by external memory
// misses interrupts, so the gap is set well clear of the 100 ms a 50 Hz
// machine would need rather than close to it.

`default_nettype none

module nexttang_load_key_sequencer #(
    parameter integer CLOCK_HZ = 3500000,
    parameter integer START_DELAY_MS = 3000,
    parameter integer HOLD_MS = 140,
    parameter integer GAP_MS = 500
) (
    input  wire        clock,
    input  wire        reset,
    output reg  [39:0] keys,
    output reg         finished
);
    localparam integer START_CYCLES = (CLOCK_HZ / 1000) * START_DELAY_MS;
    localparam integer HOLD_CYCLES = (CLOCK_HZ / 1000) * HOLD_MS;
    localparam integer GAP_CYCLES = (CLOCK_HZ / 1000) * GAP_MS;
    localparam integer STEPS = 4;

    localparam [1:0] WAITING = 2'd0;
    localparam [1:0] HOLDING = 2'd1;
    localparam [1:0] RELEASING = 2'd2;
    localparam [1:0] DONE = 2'd3;

    // {symbol shift, row, column}. J at an empty prompt produces LOAD in
    // 48K BASIC; symbol-shift plus P produces a quote.
    function [6:0] step_key(input [1:0] index);
        case (index)
            2'd0: step_key = {1'b0, 3'd6, 3'd3};  // J, gives LOAD
            2'd1: step_key = {1'b1, 3'd5, 3'd0};  // quote
            2'd2: step_key = {1'b1, 3'd5, 3'd0};  // quote
            default: step_key = {1'b0, 3'd6, 3'd0}; // ENTER
        endcase
    endfunction

    reg [1:0] state = WAITING;
    reg [1:0] step = 0;
    // Sized from the parameters, because a start delay measured in tens of
    // seconds outgrows a hand-picked counter width without saying so.
    localparam integer LONGEST_WAIT =
        (START_CYCLES > HOLD_CYCLES)
            ? ((START_CYCLES > GAP_CYCLES) ? START_CYCLES : GAP_CYCLES)
            : ((HOLD_CYCLES > GAP_CYCLES) ? HOLD_CYCLES : GAP_CYCLES);

    reg [$clog2(LONGEST_WAIT + 1) - 1:0] timer = 0;

    wire [6:0] current = step_key(step);
    wire symbol_shift = current[6];
    wire [2:0] row = current[5:3];
    wire [2:0] column = current[2:0];

    always @(posedge clock) begin
        if (reset) begin
            state <= WAITING;
            step <= 0;
            timer <= 0;
            keys <= 0;
            finished <= 1'b0;
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
                        keys[7 * 5 + 1] <= 1'b1;
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
