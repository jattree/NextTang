// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A look inside the HDMI picture path over the debug UART, for the loads
// that come up with sync and sound but a black picture (Nano 20K,
// 2026-11-16). On `request` it sends one line:
//
//     H s LL PP II VV UU OO \n      (hex, no spaces)
//
//     s    bit 3 video PLL locked, bit 2 60 Hz, bits 1:0 hdmi_frame's state
//          (0 reset, 1 waiting for the core's frame lock, 2 waiting for the
//          HDMI frame's end, 3 running)
//     LL   the core's frame lock pulses seen          (one per frame)
//     PP   rising edges of the core's pixel enable    (one per line)
//     II   pixel-enable runs with a non-black pixel in (core side)
//     VV   HDMI vertical syncs
//     UU   HDMI lines that left blanking
//     OO   HDMI lines with a non-black pixel out
//
// The counts are eight bits and wrap; ask twice and compare. The three HDMI
// counts cross from the pixel clock bit by bit, so a digit can be caught
// mid-change now and then: a diagnostic, not a measurement.

`default_nettype none

module nexttang_video_probe #(
    parameter integer CLOCK_HZ = 28125000,
    parameter integer BAUD_RATE = 115200
) (
    input  wire       clock,            // the machine clock
    input  wire       request,

    // core side (machine clock family)
    input  wire       core_lock,
    input  wire       core_pixel_enable,
    input  wire [8:0] core_rgb,

    // HDMI side
    input  wire       pixel_clock,
    input  wire [1:0] frame_state,
    input  wire       hdmi_blank,
    input  wire       hdmi_vsync_n,
    input  wire [8:0] hdmi_rgb,

    input  wire       video_60,
    input  wire       video_pll_lock,

    output wire       tx
);
    // core side
    reg       lock_q = 1'b0, enable_q = 1'b0, lit_in = 1'b0;
    reg [7:0] locks = 8'd0, enables = 8'd0, lit_ins = 8'd0;
    always @(posedge clock) begin
        lock_q <= core_lock;
        enable_q <= core_pixel_enable;
        if (core_lock && !lock_q) locks <= locks + 8'd1;
        if (core_pixel_enable && !enable_q) begin
            enables <= enables + 8'd1;
            lit_in <= 1'b0;
        end
        if (core_pixel_enable && core_rgb != 9'd0 && !lit_in) begin
            lit_in <= 1'b1;
            lit_ins <= lit_ins + 8'd1;
        end
    end

    // HDMI side
    reg       vsync_q = 1'b1, blank_q = 1'b1, lit_out = 1'b0;
    reg [7:0] vsyncs = 8'd0, unblanks = 8'd0, lit_outs = 8'd0;
    always @(posedge pixel_clock) begin
        vsync_q <= hdmi_vsync_n;
        blank_q <= hdmi_blank;
        if (!hdmi_vsync_n && vsync_q) vsyncs <= vsyncs + 8'd1;
        if (!hdmi_blank && blank_q) begin
            unblanks <= unblanks + 8'd1;
            lit_out <= 1'b0;
        end
        if (!hdmi_blank && hdmi_rgb != 9'd0 && !lit_out) begin
            lit_out <= 1'b1;
            lit_outs <= lit_outs + 8'd1;
        end
    end

    // into the machine clock
    reg [25:0] cross_a = 26'd0, cross_b = 26'd0;
    always @(posedge clock) begin
        cross_a <= {frame_state, vsyncs, unblanks, lit_outs};
        cross_b <= cross_a;
    end

    function [7:0] hex(input [3:0] n);
        hex = n < 4'd10 ? 8'h30 + {4'd0, n} : 8'h37 + {4'd0, n};
    endfunction

    // the line: 15 characters
    localparam integer BIT_CLOCKS = CLOCK_HZ / BAUD_RATE;
    reg [119:0] line = 120'd0;
    reg [3:0]   left = 4'd0;           // characters still to send
    reg [15:0]  baud = 16'd0;
    reg [3:0]   bits = 4'd0;
    reg [9:0]   shift = 10'h3ff;
    wire [3:0]  status = {video_pll_lock, video_60, cross_b[25:24]};
    always @(posedge clock) begin
        if (bits != 4'd0) begin
            if (baud == 16'd0) begin
                shift <= {1'b1, shift[9:1]};
                bits <= bits - 4'd1;
                baud <= BIT_CLOCKS[15:0] - 16'd1;
            end else
                baud <= baud - 16'd1;
        end else if (left != 4'd0) begin
            shift <= {1'b1, line[119:112], 1'b0};
            line <= {line[111:0], 8'h00};
            left <= left - 4'd1;
            bits <= 4'd10;
            baud <= BIT_CLOCKS[15:0] - 16'd1;
        end else if (request) begin
            line <= {"H", hex(status),
                     hex(locks[7:4]), hex(locks[3:0]), hex(enables[7:4]), hex(enables[3:0]),
                     hex(lit_ins[7:4]), hex(lit_ins[3:0]),
                     hex(cross_b[23:20]), hex(cross_b[19:16]), hex(cross_b[15:12]), hex(cross_b[11:8]),
                     hex(cross_b[7:4]), hex(cross_b[3:0]), 8'h0a};
            left <= 4'd15;
        end
    end
    assign tx = shift[0];
endmodule

`default_nettype wire
