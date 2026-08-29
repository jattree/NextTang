// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Live controls received on the same UART as a runtime Spec256 game pack.
// Commands are deliberately short and framed so arbitrary game-pack bytes
// cannot become input while the loader owns the stream:
//
//   "K", matrix index 0..39, 0|1   release or press a Spectrum key
//   "J", Kempston bits[4:0]        replace the complete joystick state

`default_nettype none

module nexttang_spec256_runtime_input (
    input  wire        clock,
    input  wire        reset,
    input  wire        enable,
    input  wire [7:0]  byte_data,
    input  wire        byte_valid,
    output reg  [39:0] keys,
    output reg  [4:0]  joystick
);
    localparam [1:0] STATE_COMMAND  = 2'd0;
    localparam [1:0] STATE_KEY      = 2'd1;
    localparam [1:0] STATE_KEY_VALUE = 2'd2;
    localparam [1:0] STATE_JOYSTICK = 2'd3;

    reg [1:0] state;
    reg [7:0] key_index;

    always @(posedge clock) begin
        if (reset || !enable) begin
            state <= STATE_COMMAND;
            key_index <= 0;
            keys <= 0;
            joystick <= 0;
        end else if (byte_valid) begin
            case (state)
                STATE_COMMAND: begin
                    if (byte_data == "K")
                        state <= STATE_KEY;
                    else if (byte_data == "J")
                        state <= STATE_JOYSTICK;
                end

                STATE_KEY: begin
                    key_index <= byte_data;
                    state <= STATE_KEY_VALUE;
                end

                STATE_KEY_VALUE: begin
                    if (key_index < 40) begin
                        if (byte_data == 1)
                            keys[key_index] <= 1'b1;
                        else if (byte_data == 0)
                            keys[key_index] <= 1'b0;
                    end
                    state <= STATE_COMMAND;
                end

                default: begin
                    joystick <= byte_data[4:0];
                    state <= STATE_COMMAND;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
