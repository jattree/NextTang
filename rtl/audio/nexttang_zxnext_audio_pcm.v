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
    parameter integer HOLD_CYCLES = 256,
    // 1: the phase accumulator and the two DC baselines in three Gowin GW2A
    // DSP blocks (ALU54D), freeing their logic cells; the samples are the
    // same, one `clock` later. 0: ordinary logic.
    parameter integer DSP = 0
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

    wire signed [31:0] target_left = $signed({17'd0, taken_left, 2'b00}) <<< 16;
    wire signed [31:0] target_right = $signed({17'd0, taken_right, 2'b00}) <<< 16;

    always @(posedge clock) begin
        toggle_meta <= held_toggle;
        toggle_sync <= toggle_meta;
        toggle_seen <= toggle_sync;
        if (toggle_sync != toggle_seen) begin
            taken_left <= held_left;
            taken_right <= held_right;
        end
    end

    generate
    if (DSP == 0) begin : in_logic
        reg [31:0] phase = 0;
        wire [32:0] phase_sum = {1'b0, phase} + {1'b0, PHASE_INCREMENT};
        reg signed [31:0] baseline_left = 0;
        reg signed [31:0] baseline_right = 0;
        wire signed [31:0] ac_left = target_left - baseline_left;
        wire signed [31:0] ac_right = target_right - baseline_right;
        always @(posedge clock) begin
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
    end else begin : in_dsp
        // The phase runs on in a 54-bit sum; each time its low 32 bits wrap,
        // bit 32 changes, and that change is the sample tick.
        wire [53:0] phase_sum;
        reg         phase_32 = 1'b0;
        wire        tick = phase_sum[32] != phase_32;
        ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
                 .OUT_REG(1'b1), .B_ADD_SUB(1'b0), .C_ADD_SUB(1'b0), .ALUD_MODE(0),
                 .ALU_RESET_MODE("SYNC")) phase_dsp (
            .A({22'd0, PHASE_INCREMENT}), .B(54'd0), .ASIGN(1'b0), .BSIGN(1'b0), .ACCLOAD(1'b1),
            .CASI(55'd0), .CLK(clock), .CE(1'b1), .RESET(reset), .DOUT(phase_sum), .CASO());

        // baseline <= baseline + ((target - baseline) >>> 8), with no subtract:
        // the target is a multiple of 65536, so the shifted difference is
        // target/256 + (~baseline >>> 8) + (1 when the baseline's low byte is 0),
        // and that 1 goes into the target term's empty low bits.
        wire [53:0] base_left, base_right;
        ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
                 .OUT_REG(1'b1), .B_ADD_SUB(1'b0), .C_ADD_SUB(1'b0), .ALUD_MODE(0),
                 .ALU_RESET_MODE("SYNC")) left_dsp (
            .A({30'd0, target_left[31:8]} | {53'd0, base_left[7:0] == 8'd0}),
            .B({{8{!base_left[53]}}, ~base_left[53:8]}), .ASIGN(1'b0), .BSIGN(1'b0), .ACCLOAD(1'b1),
            .CASI(55'd0), .CLK(clock), .CE(tick | reset), .RESET(reset), .DOUT(base_left), .CASO());
        ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
                 .OUT_REG(1'b1), .B_ADD_SUB(1'b0), .C_ADD_SUB(1'b0), .ALUD_MODE(0),
                 .ALU_RESET_MODE("SYNC")) right_dsp (
            .A({30'd0, target_right[31:8]} | {53'd0, base_right[7:0] == 8'd0}),
            .B({{8{!base_right[53]}}, ~base_right[53:8]}), .ASIGN(1'b0), .BSIGN(1'b0), .ACCLOAD(1'b1),
            .CASI(55'd0), .CLK(clock), .CE(tick | reset), .RESET(reset), .DOUT(base_right), .CASO());

        // The samples: (target - baseline) >>> 16, each in a DSP block
        // (A - B, taken on the tick into the block's output register, which
        // is the sample register).
        wire [53:0] out_left, out_right;
        ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
                 .OUT_REG(1'b1), .B_ADD_SUB(1'b1), .C_ADD_SUB(1'b0), .ALUD_MODE(0),
                 .ALU_RESET_MODE("SYNC")) left_out_dsp (
            .A({{22{target_left[31]}}, target_left}), .B(base_left), .ASIGN(1'b1), .BSIGN(1'b1),
            .ACCLOAD(1'b0), .CASI(55'd0), .CLK(clock), .CE(tick | reset), .RESET(reset),
            .DOUT(out_left), .CASO());
        ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
                 .OUT_REG(1'b1), .B_ADD_SUB(1'b1), .C_ADD_SUB(1'b0), .ALUD_MODE(0),
                 .ALU_RESET_MODE("SYNC")) right_out_dsp (
            .A({{22{target_right[31]}}, target_right}), .B(base_right), .ASIGN(1'b1), .BSIGN(1'b1),
            .ACCLOAD(1'b0), .CASI(55'd0), .CLK(clock), .CE(tick | reset), .RESET(reset),
            .DOUT(out_right), .CASO());
        always @* begin
            left = out_left[31:16];
            right = out_right[31:16];
        end
        always @(posedge clock) begin
            phase_32 <= phase_sum[32];
            if (reset) begin
                phase_32 <= 1'b0;
                audio_ce <= 1'b0;
            end else begin
                audio_ce <= tick;
            end
        end
    end
    endgenerate
endmodule
`default_nettype wire
