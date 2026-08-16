// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Adapt explicit 16-byte lines to the 32-byte controller beats used by the
// exact C-silicon Tang Console 138K DDR3 configuration. Two machine lines
// share each controller beat; byte masks protect the untouched half.
module nexttang_gowin_ddr3_ui_adapter (
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
    output reg          controller_command_enable,
    output reg  [28:0]  controller_address,
    input  wire         controller_write_data_ready,
    output reg  [255:0] controller_write_data,
    output reg          controller_write_data_enable,
    output wire         controller_write_data_end,
    output reg  [31:0]  controller_write_data_mask,
    input  wire [255:0] controller_read_data,
    input  wire         controller_read_data_valid,
    output wire         controller_burst
);
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_WRITE = 2'd1;
    localparam [1:0] STATE_READ_COMMAND = 2'd2;
    localparam [1:0] STATE_READ_RESPONSE = 2'd3;

    reg [1:0] state;
    reg write_command_pending;
    reg write_data_pending;
    reg read_upper_half;

    wire write_command_accepted =
        write_command_pending && controller_command_ready;
    wire write_data_accepted =
        write_data_pending && controller_write_data_ready;

    assign line_ready = state == STATE_IDLE;
    assign controller_write_data_end = 1'b1;
    assign controller_burst = 1'b0;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            write_command_pending <= 1'b0;
            write_data_pending <= 1'b0;
            read_upper_half <= 1'b0;
            line_response_valid <= 1'b0;
            line_read_data <= 0;
            controller_command <= 0;
            controller_command_enable <= 1'b0;
            controller_address <= 0;
            controller_write_data <= 0;
            controller_write_data_enable <= 1'b0;
            controller_write_data_mask <= {32{1'b1}};
        end else begin
            line_response_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    controller_command_enable <= 1'b0;
                    controller_write_data_enable <= 1'b0;
                    write_command_pending <= 1'b0;
                    write_data_pending <= 1'b0;

                    if (line_request) begin
                        controller_address <= {
                            10'b0, line_address[16:1], 3'b0
                        };
                        read_upper_half <= line_address[0];
                        if (line_write) begin
                            controller_command <= 3'b000;
                            controller_command_enable <= 1'b1;
                            controller_write_data <= line_address[0]
                                ? {line_write_data, 128'b0}
                                : {128'b0, line_write_data};
                            controller_write_data_mask <= line_address[0]
                                ? {~line_write_enable, 16'hffff}
                                : {16'hffff, ~line_write_enable};
                            controller_write_data_enable <= 1'b1;
                            write_command_pending <= 1'b1;
                            write_data_pending <= 1'b1;
                            state <= STATE_WRITE;
                        end else begin
                            controller_command <= 3'b001;
                            controller_command_enable <= 1'b1;
                            state <= STATE_READ_COMMAND;
                        end
                    end
                end

                STATE_WRITE: begin
                    if (write_command_accepted) begin
                        controller_command_enable <= 1'b0;
                        write_command_pending <= 1'b0;
                    end
                    if (write_data_accepted) begin
                        controller_write_data_enable <= 1'b0;
                        write_data_pending <= 1'b0;
                    end
                    if ((!write_command_pending || write_command_accepted) &&
                        (!write_data_pending || write_data_accepted)) begin
                        line_response_valid <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                STATE_READ_COMMAND: begin
                    if (controller_command_ready) begin
                        controller_command_enable <= 1'b0;
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
                    controller_command_enable <= 1'b0;
                    controller_write_data_enable <= 1'b0;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
