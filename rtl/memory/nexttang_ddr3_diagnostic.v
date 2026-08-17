// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Bounded destructive read/write diagnostic for an otherwise unused DDR3.
// It writes distinct data at zero, every physical 1 GiB address-line probe and
// the final aligned 32-byte beat before reading any location back.
module nexttang_ddr3_diagnostic #(
    parameter integer CALIBRATION_TIMEOUT_CYCLES = 270000000,
    parameter integer TRANSACTION_TIMEOUT_CYCLES = 25000000,
    parameter integer WRITE_DRAIN_CYCLES = 1024
) (
    input  wire         clock,
    input  wire         reset,
    input  wire         calibration_complete,
    input  wire         controller_command_ready,
    output wire [2:0]   controller_command,
    output wire         controller_command_enable,
    output wire [28:0]  controller_address,
    input  wire         controller_write_data_ready,
    output wire [255:0] controller_write_data,
    output wire         controller_write_data_enable,
    output wire         controller_write_data_end,
    output wire [31:0]  controller_write_data_mask,
    input  wire [255:0] controller_read_data,
    input  wire         controller_read_data_valid,
    output wire         controller_burst,
    output reg  [2:0]   status
);
    localparam [2:0] STATUS_CALIBRATING = 3'd0;
    localparam [2:0] STATUS_WRITING = 3'd1;
    localparam [2:0] STATUS_READING = 3'd2;
    localparam [2:0] STATUS_PASS = 3'd3;
    localparam [2:0] STATUS_DATA_ERROR = 3'd4;
    localparam [2:0] STATUS_CALIBRATION_TIMEOUT = 3'd5;
    localparam [2:0] STATUS_TRANSACTION_TIMEOUT = 3'd6;
    localparam [2:0] STATUS_CALIBRATION_LOST = 3'd7;

    localparam [2:0] STATE_WAIT_CALIBRATION = 3'd0;
    localparam [2:0] STATE_WRITE = 3'd1;
    localparam [2:0] STATE_READ_COMMAND = 3'd2;
    localparam [2:0] STATE_READ_RESPONSE = 3'd3;
    localparam [2:0] STATE_DONE = 3'd4;
    localparam [2:0] STATE_WRITE_DRAIN = 3'd5;
    localparam [4:0] LAST_TEST_INDEX = 5'd26;

    reg [2:0] state;
    reg [4:0] test_index;
    reg write_command_pending;
    reg write_data_pending;
    reg [31:0] timeout_counter;
    reg [28:0] current_address;
    reg [255:0] current_pattern;

    wire write_command_accepted =
        write_command_pending && controller_command_ready;
    wire write_data_accepted =
        write_data_pending && controller_write_data_ready;
    wire write_complete =
        (!write_command_pending || write_command_accepted) &&
        (!write_data_pending || write_data_accepted);

    function [28:0] test_address;
        input [4:0] index;
        begin
            // The UI address is in 32-bit words and each 256-bit transfer is
            // aligned to eight words. Bits 3 through 27 therefore select all
            // 32-byte beats in the fitted 1 GiB memory.
            if (index == 0)
                test_address = 29'h00000000;
            else if (index < LAST_TEST_INDEX)
                test_address = 29'h00000008 << (index - 1'b1);
            else
                test_address = 29'h0ffffff8;
        end
    endfunction

    function [255:0] test_pattern;
        input [4:0] index;
        reg [31:0] signature;
        begin
            signature = 32'h4e540000 | index;
            test_pattern = {
                signature,
                ~signature,
                signature ^ 32'h55555555,
                signature ^ 32'haaaaaaaa,
                signature ^ 32'h01234567,
                signature ^ 32'h89abcdef,
                signature ^ 32'hf00ff00f,
                signature ^ 32'h0ff00ff0
            };
        end
    endfunction

    assign controller_command = state == STATE_WRITE ? 3'b000 : 3'b001;
    assign controller_command_enable =
        (state == STATE_WRITE && write_command_pending) ||
        state == STATE_READ_COMMAND;
    assign controller_address = current_address;
    assign controller_write_data = current_pattern;
    assign controller_write_data_enable =
        state == STATE_WRITE && write_data_pending;
    assign controller_write_data_end = 1'b1;
    assign controller_write_data_mask = 32'b0;
    assign controller_burst = 1'b0;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= STATE_WAIT_CALIBRATION;
            test_index <= 0;
            write_command_pending <= 1'b0;
            write_data_pending <= 1'b0;
            timeout_counter <= 0;
            current_address <= 0;
            current_pattern <= 0;
            status <= STATUS_CALIBRATING;
        end else begin
            case (state)
                STATE_WAIT_CALIBRATION: begin
                    if (calibration_complete) begin
                        state <= STATE_WRITE;
                        test_index <= 0;
                        write_command_pending <= 1'b1;
                        write_data_pending <= 1'b1;
                        timeout_counter <= 0;
                        current_address <= test_address(0);
                        current_pattern <= test_pattern(0);
                        status <= STATUS_WRITING;
                    end else if (timeout_counter >=
                                 CALIBRATION_TIMEOUT_CYCLES - 1) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_TIMEOUT;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                STATE_WRITE: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (write_complete) begin
                        timeout_counter <= 0;
                        if (test_index == LAST_TEST_INDEX) begin
                            state <= STATE_WRITE_DRAIN;
                            test_index <= 0;
                            current_address <= test_address(0);
                            current_pattern <= test_pattern(0);
                            write_command_pending <= 1'b0;
                            write_data_pending <= 1'b0;
                        end else begin
                            test_index <= test_index + 1'b1;
                            current_address <= test_address(test_index + 1'b1);
                            current_pattern <= test_pattern(test_index + 1'b1);
                            write_command_pending <= 1'b1;
                            write_data_pending <= 1'b1;
                        end
                    end else if (timeout_counter >=
                                 TRANSACTION_TIMEOUT_CYCLES - 1) begin
                        state <= STATE_DONE;
                        status <= STATUS_TRANSACTION_TIMEOUT;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                        if (write_command_accepted)
                            write_command_pending <= 1'b0;
                        if (write_data_accepted)
                            write_data_pending <= 1'b0;
                    end
                end

                STATE_WRITE_DRAIN: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (timeout_counter >=
                                 WRITE_DRAIN_CYCLES - 1) begin
                        state <= STATE_READ_COMMAND;
                        timeout_counter <= 0;
                        status <= STATUS_READING;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                STATE_READ_COMMAND: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (controller_command_ready) begin
                        timeout_counter <= 0;
                        if (controller_read_data_valid) begin
                            if (controller_read_data != current_pattern) begin
                                state <= STATE_DONE;
                                status <= STATUS_DATA_ERROR;
                            end else if (test_index == LAST_TEST_INDEX) begin
                                state <= STATE_DONE;
                                status <= STATUS_PASS;
                            end else begin
                                test_index <= test_index + 1'b1;
                                current_address <= test_address(
                                    test_index + 1'b1
                                );
                                current_pattern <= test_pattern(
                                    test_index + 1'b1
                                );
                            end
                        end else begin
                            state <= STATE_READ_RESPONSE;
                        end
                    end else if (timeout_counter >=
                                 TRANSACTION_TIMEOUT_CYCLES - 1) begin
                        state <= STATE_DONE;
                        status <= STATUS_TRANSACTION_TIMEOUT;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                STATE_READ_RESPONSE: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (controller_read_data_valid) begin
                        timeout_counter <= 0;
                        if (controller_read_data != current_pattern) begin
                            state <= STATE_DONE;
                            status <= STATUS_DATA_ERROR;
                        end else if (test_index == LAST_TEST_INDEX) begin
                            state <= STATE_DONE;
                            status <= STATUS_PASS;
                        end else begin
                            test_index <= test_index + 1'b1;
                            current_address <= test_address(
                                test_index + 1'b1
                            );
                            current_pattern <= test_pattern(
                                test_index + 1'b1
                            );
                            state <= STATE_READ_COMMAND;
                        end
                    end else if (timeout_counter >=
                                 TRANSACTION_TIMEOUT_CYCLES - 1) begin
                        state <= STATE_DONE;
                        status <= STATUS_TRANSACTION_TIMEOUT;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                default: begin
                    state <= STATE_DONE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
