// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Standard I2S out of two signed 16-bit channels, for an I2S amplifier such
// as the Tang Nano 20K's MAX98357A.
//
// BCLK is the clock divided by 2 * BCLK_HALF; a frame is 32 BCLKs (16-bit
// left with LRCLK low, then 16-bit right with LRCLK high), the MSB one BCLK
// after the LRCLK edge, data changing on BCLK's falling edge. Both channels
// are taken at the start of each frame. With a 28.125 MHz clock and
// BCLK_HALF 9: BCLK 1.5625 MHz, 48.828 kHz frames (BCLK/LRCLK = 32).
`default_nettype none

module nexttang_i2s_transmitter #(
    parameter integer BCLK_HALF = 9
) (
    input  wire               clock,
    input  wire               reset,
    input  wire signed [15:0] left,
    input  wire signed [15:0] right,
    output reg                bclk = 1'b0,
    output reg                lrclk = 1'b0,
    output reg                data = 1'b0
);
    reg [7:0]  divide = 8'd0;     // clocks within a BCLK half
    reg [4:0]  slot = 5'd0;       // BCLK within the frame
    reg [15:0] left_q = 16'd0, right_q = 16'd0;

    always @(posedge clock) begin
        if (reset) begin
            divide <= 8'd0; slot <= 5'd0; bclk <= 1'b0; lrclk <= 1'b0; data <= 1'b0;
        end else if (divide != BCLK_HALF[7:0] - 8'd1) begin
            divide <= divide + 8'd1;
        end else begin
            divide <= 8'd0;
            bclk <= !bclk;
            if (bclk) begin
                // falling edge: the next slot begins
                slot <= slot + 5'd1;
                lrclk <= (slot + 5'd1) >= 5'd16;
                case (slot + 5'd1)
                    5'd0: begin
                        data <= right_q[0];          // the finished right word's LSB
                        left_q <= left; right_q <= right;
                    end
                    default: data <= (slot + 5'd1) <= 5'd16 ? left_q[5'd16 - (slot + 5'd1)]
                                                            : right_q[5'd16 - ((slot + 5'd1) - 5'd16)];
                endcase
            end
        end
    end
endmodule

`default_nettype wire
