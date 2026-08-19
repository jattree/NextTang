// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Eight bit UART receiver, no parity, one stop bit.
//
// The line is asynchronous to this clock, so it is synchronised before the
// start bit is looked for, and each bit is sampled in its middle rather than at
// its edge. A frame whose stop bit is not high is dropped rather than reported,
// because the sender is free running and a resynchronisation costs one byte.

`default_nettype none

module nexttang_uart_receiver #(
    parameter integer CLOCK_HZ = 3500000,
    parameter integer BAUD_RATE = 2000000
) (
    input  wire       clock,
    input  wire       reset,
    input  wire       receive,
    output reg  [7:0] data,
    output reg        data_valid
);
    // Rounded to nearest so the sampling point does not drift across a frame.
    localparam integer CLOCKS_PER_BIT = (CLOCK_HZ + BAUD_RATE / 2) / BAUD_RATE;
    localparam integer HALF_BIT = CLOCKS_PER_BIT / 2;
    localparam integer COUNT_BITS = $clog2(CLOCKS_PER_BIT + 1);

    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA = 2'd2;
    localparam [1:0] STOP = 2'd3;

    reg [1:0] state;
    reg [COUNT_BITS-1:0] counter;
    reg [2:0] bit_index;
    reg [7:0] shifter;
    reg receive_meta;
    reg receive_sync;

    always @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
            counter <= 0;
            bit_index <= 0;
            shifter <= 0;
            data <= 0;
            data_valid <= 1'b0;
            receive_meta <= 1'b1;
            receive_sync <= 1'b1;
        end else begin
            receive_meta <= receive;
            receive_sync <= receive_meta;
            data_valid <= 1'b0;

            case (state)
                IDLE: begin
                    counter <= 0;
                    if (!receive_sync)
                        state <= START;
                end

                START: begin
                    // Confirm the start bit at its middle; a glitch that has
                    // gone away by then was never a frame.
                    if (counter == HALF_BIT - 1) begin
                        counter <= 0;
                        if (receive_sync) begin
                            state <= IDLE;
                        end else begin
                            bit_index <= 0;
                            state <= DATA;
                        end
                    end else begin
                        counter <= counter + 1'b1;
                    end
                end

                DATA: begin
                    if (counter == CLOCKS_PER_BIT - 1) begin
                        counter <= 0;
                        shifter <= {receive_sync, shifter[7:1]};
                        if (bit_index == 3'd7)
                            state <= STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end else begin
                        counter <= counter + 1'b1;
                    end
                end

                default: begin
                    if (counter == CLOCKS_PER_BIT - 1) begin
                        counter <= 0;
                        state <= IDLE;
                        if (receive_sync) begin
                            data <= shifter;
                            data_valid <= 1'b1;
                        end
                    end else begin
                        counter <= counter + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
