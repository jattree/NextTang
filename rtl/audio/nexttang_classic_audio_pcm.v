// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Mix the one-bit beeper and three unsigned AY channels, remove their DC
// baseline, and emit signed stereo-ready 48 kHz PCM.
module nexttang_classic_audio_pcm #(
    parameter [31:0] PHASE_INCREMENT = 32'd2771878
) (
    input  wire              clock,
    input  wire              reset,
    input  wire              beeper,
    input  wire              ay_enable,
    input  wire [7:0]        ay_a,
    input  wire [7:0]        ay_b,
    input  wire [7:0]        ay_c,
    output reg               audio_ce,
    output reg signed [15:0] sample
);
    reg [31:0] phase = 0;
    reg beeper_meta = 0, beeper_sync = 0;
    reg [7:0] ay_a_meta = 0, ay_b_meta = 0, ay_c_meta = 0;
    reg [7:0] ay_a_sync = 0, ay_b_sync = 0, ay_c_sync = 0;
    reg signed [31:0] baseline_q = 0;
    wire [32:0] phase_sum = {1'b0, phase} + {1'b0, PHASE_INCREMENT};
    wire signed [18:0] ay_sum = ay_enable ?
        ($signed({1'b0, ay_a_sync}) + $signed({1'b0, ay_b_sync}) +
         $signed({1'b0, ay_c_sync})) * 19'sd16 : 19'sd0;
    wire signed [18:0] target = (beeper_sync ? 19'sd4096 : -19'sd4096) + ay_sum;
    wire signed [31:0] target_q = target <<< 16;
    wire signed [31:0] ac_q = target_q - baseline_q;

    always @(posedge clock) begin
        if (reset) begin
            phase <= 0; audio_ce <= 0; sample <= 0;
            beeper_meta <= 0; beeper_sync <= 0;
            ay_a_meta <= 0; ay_b_meta <= 0; ay_c_meta <= 0;
            ay_a_sync <= 0; ay_b_sync <= 0; ay_c_sync <= 0;
            baseline_q <= -(32'sd4096 <<< 16);
        end else begin
            phase <= phase_sum[31:0];
            audio_ce <= phase_sum[32];
            beeper_meta <= beeper; beeper_sync <= beeper_meta;
            ay_a_meta <= ay_a; ay_b_meta <= ay_b; ay_c_meta <= ay_c;
            ay_a_sync <= ay_a_meta; ay_b_sync <= ay_b_meta; ay_c_sync <= ay_c_meta;
            if (phase_sum[32]) begin
                baseline_q <= baseline_q + (ac_q >>> 8);
                sample <= ac_q >>> 16;
            end
        end
    end
endmodule

`default_nettype wire
