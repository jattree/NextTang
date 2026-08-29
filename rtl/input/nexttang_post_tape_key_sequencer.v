// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Press one configured Spectrum matrix key after tape playback completes.
// Keeping this separate from the LOAD typist lets each game opt in to the
// start key it actually uses without changing generic tape behaviour.

`default_nettype none

module nexttang_post_tape_key_sequencer #(
    parameter integer CLOCK_HZ = 3500000,
    parameter integer START_DELAY_MS = 2000,
    parameter integer HOLD_MS = 140,
    parameter integer GAP_MS = 500,
    parameter integer KEY_ROW = 0,
    parameter integer KEY_COLUMN = 0,
    parameter integer SECOND_KEY_ENABLE = 0,
    parameter integer SECOND_KEY_ROW = 0,
    parameter integer SECOND_KEY_COLUMN = 0
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        start,
    output reg  [39:0] keys,
    output reg         finished
);
    localparam integer START_CYCLES_RAW =
        (CLOCK_HZ / 1000) * START_DELAY_MS;
    localparam integer HOLD_CYCLES_RAW = (CLOCK_HZ / 1000) * HOLD_MS;
    localparam integer GAP_CYCLES_RAW = (CLOCK_HZ / 1000) * GAP_MS;
    localparam integer START_CYCLES = START_CYCLES_RAW > 0
        ? START_CYCLES_RAW : 1;
    localparam integer HOLD_CYCLES = HOLD_CYCLES_RAW > 0
        ? HOLD_CYCLES_RAW : 1;
    localparam integer GAP_CYCLES = GAP_CYCLES_RAW > 0
        ? GAP_CYCLES_RAW : 1;
    localparam integer LONGEST_WAIT =
        (START_CYCLES > HOLD_CYCLES)
            ? ((START_CYCLES > GAP_CYCLES) ? START_CYCLES : GAP_CYCLES)
            : ((HOLD_CYCLES > GAP_CYCLES) ? HOLD_CYCLES : GAP_CYCLES);

    localparam [1:0] WAITING = 2'd0;
    localparam [1:0] DELAYING = 2'd1;
    localparam [1:0] HOLDING = 2'd2;
    localparam [1:0] RELEASING = 2'd3;

    reg [1:0] state = WAITING;
    reg second_key = 1'b0;
    reg [$clog2(LONGEST_WAIT + 1) - 1:0] timer = 0;

    always @* begin
        keys = 0;
        if (state == HOLDING) begin
            if (second_key)
                keys[SECOND_KEY_ROW * 5 + SECOND_KEY_COLUMN] = 1'b1;
            else
                keys[KEY_ROW * 5 + KEY_COLUMN] = 1'b1;
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            state <= WAITING;
            second_key <= 1'b0;
            timer <= 0;
            finished <= 1'b0;
        end else begin
            case (state)
                WAITING: begin
                    if (start && !finished) begin
                        timer <= 0;
                        state <= DELAYING;
                    end
                end

                DELAYING: begin
                    if (timer == START_CYCLES - 1) begin
                        timer <= 0;
                        state <= HOLDING;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                HOLDING: begin
                    if (timer == HOLD_CYCLES - 1) begin
                        timer <= 0;
                        if ((SECOND_KEY_ENABLE != 0) && !second_key) begin
                            second_key <= 1'b1;
                            state <= RELEASING;
                        end else begin
                            finished <= 1'b1;
                            state <= WAITING;
                        end
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                RELEASING: begin
                    if (timer == GAP_CYCLES - 1) begin
                        timer <= 0;
                        state <= HOLDING;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                default: begin
                    state <= WAITING;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
