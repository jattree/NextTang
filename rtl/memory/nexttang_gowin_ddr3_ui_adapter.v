// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Adapt explicit 16-byte lines to the 32-byte controller beats used by the
// exact C-silicon Tang Console 138K DDR3 configuration. Two machine lines
// share each controller beat; byte masks protect the untouched half.
module nexttang_gowin_ddr3_ui_adapter #(
    parameter integer WRITE_DRAIN_CYCLES = 1024
) (
    input  wire         clock,
    input  wire         reset,

    input  wire         line_request,
    output wire         line_ready,
    input  wire         line_write,
    input  wire [16:0]  line_address,
    input  wire [127:0] line_write_data,
    input  wire [15:0]  line_write_enable,
    output reg          line_response_valid,
    output reg  [127:0] line_read_data,

    input  wire         controller_command_ready,
    output reg  [2:0]   controller_command,
    output wire         controller_command_enable,
    output reg  [28:0]  controller_address,
    input  wire         controller_write_data_ready,
    output reg  [255:0] controller_write_data,
    output wire         controller_write_data_enable,
    output wire         controller_write_data_end,
    output reg  [31:0]  controller_write_data_mask,
    input  wire [255:0] controller_read_data,
    input  wire         controller_read_data_valid,
    output wire         controller_burst
);
    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_WRITE = 3'd1;
    localparam [2:0] STATE_WRITE_DRAIN = 3'd2;
    localparam [2:0] STATE_READ_COMMAND = 3'd3;
    localparam [2:0] STATE_READ_RESPONSE = 3'd4;

    reg [2:0] state;
    reg [31:0] write_drain_counter;
    reg read_upper_half;

    wire write_pair_ready = controller_command_ready &&
                            controller_write_data_ready;

    assign line_ready = state == STATE_IDLE;
    // The exact-C controller only passed hardware readback when command and
    // write data were presented as one paired transaction. Do not let either
    // channel be accepted alone even though the public interface exposes
    // separate ready signals.
    assign controller_command_enable =
        (state == STATE_WRITE && write_pair_ready) ||
        state == STATE_READ_COMMAND;
    assign controller_write_data_enable =
        state == STATE_WRITE && write_pair_ready;
    assign controller_write_data_end = 1'b1;
    assign controller_burst = 1'b0;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            write_drain_counter <= 0;
            read_upper_half <= 1'b0;
            line_response_valid <= 1'b0;
            line_read_data <= 0;
            controller_command <= 0;
            controller_address <= 0;
            controller_write_data <= 0;
            controller_write_data_mask <= {32{1'b1}};
        end else begin
            line_response_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    write_drain_counter <= 0;

                    if (line_request) begin
                        controller_address <= {
                            10'b0, line_address[16:1], 3'b0
                        };
                        read_upper_half <= line_address[0];
                        if (line_write) begin
                            controller_command <= 3'b000;
                            controller_write_data <= line_address[0]
                                ? {line_write_data, 128'b0}
                                : {128'b0, line_write_data};
                            controller_write_data_mask <= line_address[0]
                                ? {~line_write_enable, 16'hffff}
                                : {16'hffff, ~line_write_enable};
                            state <= STATE_WRITE;
                        end else begin
                            controller_command <= 3'b001;
                            state <= STATE_READ_COMMAND;
                        end
                    end
                end

                STATE_WRITE: begin
                    if (write_pair_ready) begin
                        write_drain_counter <= 0;
                        state <= STATE_WRITE_DRAIN;
                    end
                end

                STATE_WRITE_DRAIN: begin
                    // Acceptance only queues the write inside the vendor
                    // controller. The hardware-proven boundary waits before
                    // allowing a dependent CPU transaction to follow it.
                    if (WRITE_DRAIN_CYCLES == 0 ||
                        write_drain_counter + 1 >= WRITE_DRAIN_CYCLES) begin
                        line_response_valid <= 1'b1;
                        state <= STATE_IDLE;
                    end else begin
                        write_drain_counter <= write_drain_counter + 1'b1;
                    end
                end

                STATE_READ_COMMAND: begin
                    if (controller_command_ready) begin
                        if (controller_read_data_valid) begin
                            line_read_data <= read_upper_half
                                ? controller_read_data[255:128]
                                : controller_read_data[127:0];
                            line_response_valid <= 1'b1;
                            state <= STATE_IDLE;
                        end else begin
                            state <= STATE_READ_RESPONSE;
                        end
                    end
                end

                STATE_READ_RESPONSE: begin
                    if (controller_read_data_valid) begin
                        line_read_data <= read_upper_half
                            ? controller_read_data[255:128]
                            : controller_read_data[127:0];
                        line_response_valid <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
