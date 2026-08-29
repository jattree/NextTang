// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Pulls key presses out of the BL616's message stream.
//
// A USB keyboard on the board's own USB-A ports is read by the BL616, which is
// running the factory TangCore firmware. It converts what it reads into PS/2
// scan codes and sends them to the FPGA over a 2 Mbit/s UART. Nothing here
// needs the MCU firmware changed and nothing needs extra hardware.
//
// The frame is a 0xAA sync byte, a sixteen bit big-endian length, a command,
// and then length minus one parameter bytes. Command 0x0c carries scan codes,
// one per parameter byte. Every other command is skipped by counting, so a
// core that ignores overlay text or ROM loading still stays in step with the
// stream. Source: nand2mario/nestang, src/iosys/iosys_bl616.v.

`default_nettype none

module nexttang_bl616_keyboard #(
    parameter integer CLOCK_HZ = 3500000,
    parameter integer BAUD_RATE = 2000000
) (
    input  wire       clock,
    input  wire       reset,
    input  wire       receive,
    output reg  [7:0] scancode,
    output reg        scancode_valid,
    output wire       debug_byte_valid,
    output reg        debug_sync_valid
);
    localparam [7:0] SYNC = 8'haa;
    localparam [7:0] COMMAND_SCANCODE = 8'h0c;

    // A length byte above 7 cannot be a real frame, so treat it as a lost sync
    // rather than waiting out a bogus 64k of parameters.
    localparam [7:0] LENGTH_LIMIT = 8'd8;

    localparam [2:0] WAIT_SYNC = 3'd0;
    localparam [2:0] LENGTH_HIGH = 3'd1;
    localparam [2:0] LENGTH_LOW = 3'd2;
    localparam [2:0] COMMAND = 3'd3;
    localparam [2:0] PARAMETER = 3'd4;

    reg [2:0] state;
    reg [15:0] remaining;
    reg is_scancode;

    wire [7:0] byte_data;
    wire byte_valid;

    assign debug_byte_valid = byte_valid;

    nexttang_uart_receiver #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) receiver (
        .clock(clock),
        .reset(reset),
        .receive(receive),
        .data(byte_data),
        .data_valid(byte_valid)
    );

    always @(posedge clock) begin
        if (reset) begin
            state <= WAIT_SYNC;
            remaining <= 0;
            is_scancode <= 1'b0;
            scancode <= 0;
            scancode_valid <= 1'b0;
            debug_sync_valid <= 1'b0;
        end else begin
            scancode_valid <= 1'b0;
            debug_sync_valid <= 1'b0;

            if (byte_valid) begin
                case (state)
                    WAIT_SYNC: begin
                        if (byte_data == SYNC) begin
                            state <= LENGTH_HIGH;
                            debug_sync_valid <= 1'b1;
                        end
                    end

                    LENGTH_HIGH: begin
                        remaining[15:8] <= byte_data;
                        state <= byte_data < LENGTH_LIMIT
                            ? LENGTH_LOW : WAIT_SYNC;
                    end

                    LENGTH_LOW: begin
                        remaining[7:0] <= byte_data;
                        state <= COMMAND;
                    end

                    COMMAND: begin
                        is_scancode <= byte_data == COMMAND_SCANCODE;
                        // The length counts the command itself.
                        if (remaining > 16'd1) begin
                            remaining <= remaining - 16'd1;
                            state <= PARAMETER;
                        end else begin
                            state <= WAIT_SYNC;
                        end
                    end

                    default: begin
                        if (is_scancode) begin
                            scancode <= byte_data;
                            scancode_valid <= 1'b1;
                        end
                        if (remaining > 16'd1)
                            remaining <= remaining - 16'd1;
                        else
                            state <= WAIT_SYNC;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
