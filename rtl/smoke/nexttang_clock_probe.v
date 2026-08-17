// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Measures a second, unrelated clock against the board clock and reports the
// result as a colour, so the answer is visible without a UART or a debugger.
//
// The Console has two clock inputs: 50 MHz on V22 and the MS5351's output on
// V10.  Sipeed generate 720p60 from the V10 reference, but the MS5351 is
// configured over I2C by the BL616 rather than by the FPGA, so whether that
// clock is present after a JTAG load is unknown.  This answers that without
// depending on it: the video path keeps running from the board clock while this
// counts the other one.
//
// Method is a gated counter rather than a clock-domain-crossed value.  A gate
// is generated in the local domain and synchronised into the measured domain,
// which counts only while the gate is high.  The result register therefore
// changes only at the falling edge of the gate and is static by the time the
// local domain reads it, so no multi-bit crossing is exposed.  A dead measured
// clock never advances its synchroniser and leaves the result at zero, which is
// itself the answer.

`default_nettype none

module nexttang_clock_probe #(
    parameter integer CLOCK_HZ = 50000000,   // local clock, and the gate window
    parameter integer EXPECT_A_HZ = 27000000,
    parameter integer EXPECT_B_HZ = 50000000,
    parameter integer TOLERANCE_DIV = 100,   // accept within 1/TOLERANCE_DIV
    parameter integer MEASURE_BY_SAMPLING = 0
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        measured_clock,
    output reg  [31:0] measured_hz,
    output reg         measured_valid,
    output wire [2:0]  colour            // {red, green, blue}
);
    localparam integer TOLERANCE_A = EXPECT_A_HZ / TOLERANCE_DIV;
    localparam integer TOLERANCE_B = EXPECT_B_HZ / TOLERANCE_DIV;

    // Gate generation in the local domain.  High for exactly one window, then
    // low long enough for the measured domain to latch and settle.
    reg [31:0] window = 0;
    reg        gate = 1'b0;
    reg [7:0]  settle = 0;

    always @(posedge clock) begin
        if (reset) begin
            window <= 0;
            gate <= 1'b0;
            settle <= 0;
            measured_hz <= 0;
            measured_valid <= 1'b0;
        end else if (gate) begin
            if (window == CLOCK_HZ - 1) begin
                gate <= 1'b0;
                window <= 0;
                settle <= 8'hff;
            end else begin
                window <= window + 1'b1;
            end
        end else if (settle != 0) begin
            settle <= settle - 1'b1;
            if (settle == 1) begin
                // The measured domain stopped counting when the gate fell, so
                // its result has been static for 255 local cycles.
                measured_hz <= result;
                measured_valid <= 1'b1;
            end
        end else begin
            gate <= 1'b1;
        end
    end

    reg [31:0] counter = 0;
    reg [31:0] result = 0;

    generate
    if (MEASURE_BY_SAMPLING) begin : sampled
        // Slow input: synchronise it in and count rising edges locally.
        reg [2:0] input_sync = 3'b000;

        always @(posedge clock) begin
            input_sync <= {input_sync[1:0], measured_clock};
            if (gate) begin
                if (input_sync[2:1] == 2'b01)
                    counter <= counter + 1'b1;
            end else if (counter != 0) begin
                result <= counter;
                counter <= 0;
            end
        end
    end else begin : gated
        // Measured domain.  Nothing here runs if the clock is absent.
        reg [1:0] gate_sync = 2'b00;

        always @(posedge measured_clock) begin
            gate_sync <= {gate_sync[0], gate};
            if (gate_sync[1]) begin
                counter <= counter + 1'b1;
            end else if (counter != 0) begin
                result <= counter;
                counter <= 0;
            end
        end
    end
    endgenerate

    wire near_a = measured_valid &&
                  (measured_hz > EXPECT_A_HZ - TOLERANCE_A) &&
                  (measured_hz < EXPECT_A_HZ + TOLERANCE_A);
    wire near_b = measured_valid &&
                  (measured_hz > EXPECT_B_HZ - TOLERANCE_B) &&
                  (measured_hz < EXPECT_B_HZ + TOLERANCE_B);
    wire dead = measured_valid && (measured_hz == 0);

    // red: no clock.  green: the expected reference.  blue: the board clock.
    // white: running, but at neither expected rate.  black: not measured yet.
    assign colour = dead     ? 3'b100 :
                    near_a   ? 3'b010 :
                    near_b   ? 3'b001 :
                    measured_valid ? 3'b111 : 3'b000;
endmodule

`default_nettype wire
