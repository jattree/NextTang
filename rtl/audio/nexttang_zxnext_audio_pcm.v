// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
`default_nettype none
// Carry the ZXNext core's mixed stereo audio to the HDMI pixel clock as signed
// 48 kHz PCM.
//
// The core mixes beeper, AY, DAC and the rest into two unsigned 13-bit
// channels in its 28 MHz domain. Every HOLD_CYCLES of that clock both channels
// are copied into hold registers and a toggle flips; the pixel domain
// synchronises the toggle and, when it changes, takes the held pair, which
// stays still for far longer than the synchroniser needs. A phase accumulator
// makes the 48 kHz sample enable, as nexttang_classic_audio_pcm does, and each
// channel loses its DC baseline the same way, so silence sits at zero.
module nexttang_zxnext_audio_pcm #(
    // The HDMI transmitter announces 48 kHz against a 74.25 MHz pixel clock,
    // so a sink regenerates 48 kHz * 75 / 74.25 = 48.485 kHz from this
    // board's 75 MHz. Samples go out at that rate, 48000 / 74.25e6 * 2^32,
    // so the sink's buffer neither fills nor drains.
    parameter [31:0] PHASE_INCREMENT = 32'd2776545,
    parameter integer HOLD_CYCLES = 256
) (
    input  wire              core_clock,
    input  wire [12:0]       core_left,
    input  wire [12:0]       core_right,

    input  wire              clock,
    input  wire              reset,
    output reg               audio_ce,
    output reg signed [15:0] left,
    output reg signed [15:0] right
);
    // --------------------------------------------------------- core domain
    reg [12:0] held_left = 13'd0;
    reg [12:0] held_right = 13'd0;
    reg        held_toggle = 1'b0;
    reg [$clog2(HOLD_CYCLES)-1:0] hold_count = 0;

    always @(posedge core_clock) begin
        hold_count <= hold_count + 1'b1;
        if (hold_count == 0) begin
            held_left <= core_left;
            held_right <= core_right;
            held_toggle <= !held_toggle;
        end
    end

    // -------------------------------------------------------- pixel domain
    (* async_reg = "true" *) reg toggle_meta = 1'b0;
    (* async_reg = "true" *) reg toggle_sync = 1'b0;
    reg toggle_seen = 1'b0;
    reg [12:0] taken_left = 13'd0;
    reg [12:0] taken_right = 13'd0;

    reg [31:0] phase = 0;
    wire [32:0] phase_sum = {1'b0, phase} + {1'b0, PHASE_INCREMENT};

    reg signed [31:0] baseline_left = 0;
    reg signed [31:0] baseline_right = 0;
    wire signed [31:0] target_left = $signed({17'd0, taken_left, 2'b00}) <<< 16;
    wire signed [31:0] target_right = $signed({17'd0, taken_right, 2'b00}) <<< 16;
    wire signed [31:0] ac_left = target_left - baseline_left;
    wire signed [31:0] ac_right = target_right - baseline_right;

    always @(posedge clock) begin
        toggle_meta <= held_toggle;
        toggle_sync <= toggle_meta;
        toggle_seen <= toggle_sync;
        if (toggle_sync != toggle_seen) begin
            taken_left <= held_left;
            taken_right <= held_right;
        end

        if (reset) begin
            phase <= 0;
            audio_ce <= 1'b0;
            left <= 0;
            right <= 0;
            baseline_left <= 0;
            baseline_right <= 0;
        end else begin
            phase <= phase_sum[31:0];
            audio_ce <= phase_sum[32];
            if (phase_sum[32]) begin
                baseline_left <= baseline_left + (ac_left >>> 8);
                baseline_right <= baseline_right + (ac_right >>> 8);
                left <= ac_left >>> 16;
                right <= ac_right >>> 16;
            end
        end
    end
endmodule
`default_nettype wire
