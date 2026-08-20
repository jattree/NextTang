// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Stores an RGB332 logo in DDR3 and refills the inactive display buffer from
// each returned 256-bit beat. Write command and data are issued as one paired
// transaction.
module nexttang_ddr3_logo_engine #(
    parameter LOGO_FILE = "rtl/smoke/nexttang_logo_128x128_rgb332.mem",
    parameter integer LOGO_BEATS = 512,
    parameter integer BEAT_ADDRESS_WIDTH = 9,
    parameter [28:0] LOGO_BASE_ADDRESS = 29'h01000000,
    parameter integer CALIBRATION_TIMEOUT_CYCLES = 270000000,
    parameter integer TRANSACTION_TIMEOUT_CYCLES = 25000000,
    parameter integer WRITE_DRAIN_CYCLES = 1024
) (
    input  wire         clock,
    input  wire         reset,
    input  wire         calibration_complete,
    input  wire         reload_request_toggle,
    input  wire         reload_request_bank,
    output reg          completion_toggle,
    output reg          completion_bank,
    output reg          logo_ready,
    output reg          buffer_write_enable,
    output reg          buffer_write_bank,
    output reg  [BEAT_ADDRESS_WIDTH-1:0] buffer_write_address,
    output reg  [255:0] buffer_write_data,
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
    localparam [2:0] STATUS_CALIBRATION_TIMEOUT = 3'd5;
    localparam [2:0] STATUS_TRANSACTION_TIMEOUT = 3'd6;
    localparam [2:0] STATUS_CALIBRATION_LOST = 3'd7;

    localparam [3:0] STATE_WAIT_CALIBRATION = 4'd0;
    localparam [3:0] STATE_FETCH_WRITE_BYTE = 4'd1;
    localparam [3:0] STATE_STORE_WRITE_BYTE = 4'd2;
    localparam [3:0] STATE_WRITE = 4'd3;
    localparam [3:0] STATE_WRITE_DRAIN = 4'd4;
    localparam [3:0] STATE_FETCH_READ_BYTE = 4'd5;
    localparam [3:0] STATE_STORE_READ_BYTE = 4'd6;
    localparam [3:0] STATE_READ_COMMAND = 4'd7;
    localparam [3:0] STATE_READ_RESPONSE = 4'd8;
    localparam [3:0] STATE_WAIT_REQUEST = 4'd9;
    localparam [3:0] STATE_DONE = 4'd10;

    reg [7:0] source_pixels [0:LOGO_BEATS * 32 - 1];
    reg [3:0] state;
    reg [BEAT_ADDRESS_WIDTH-1:0] beat_index;
    reg [4:0] byte_index;
    reg [7:0] source_byte;
    reg [255:0] source_data;
    reg [31:0] timeout_counter;
    reg request_seen;
    reg target_bank;

    initial begin
        $readmemh(LOGO_FILE, source_pixels);
    end

    wire write_pair_ready = controller_command_ready &&
                            controller_write_data_ready;
    wire final_beat = beat_index == LOGO_BEATS - 1;
    wire [BEAT_ADDRESS_WIDTH+4:0] source_address =
        {beat_index, 5'b00000} + byte_index;

    assign controller_command = state == STATE_WRITE ? 3'b000 : 3'b001;
    assign controller_command_enable =
        (state == STATE_WRITE && write_pair_ready) ||
        (state == STATE_READ_COMMAND && controller_command_ready);
    assign controller_address = LOGO_BASE_ADDRESS +
        {{(26-BEAT_ADDRESS_WIDTH){1'b0}}, beat_index, 3'b000};
    assign controller_write_data = source_data;
    assign controller_write_data_enable =
        state == STATE_WRITE && write_pair_ready;
    assign controller_write_data_end = 1'b1;
    assign controller_write_data_mask = 32'b0;
    assign controller_burst = 1'b0;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= STATE_WAIT_CALIBRATION;
            beat_index <= 0;
            byte_index <= 0;
            source_byte <= 0;
            source_data <= 0;
            timeout_counter <= 0;
            request_seen <= 0;
            target_bank <= 0;
            completion_toggle <= 0;
            completion_bank <= 0;
            logo_ready <= 0;
            buffer_write_enable <= 0;
            buffer_write_bank <= 0;
            buffer_write_address <= 0;
            buffer_write_data <= 0;
            status <= STATUS_CALIBRATING;
        end else begin
            buffer_write_enable <= 0;
            case (state)
                STATE_WAIT_CALIBRATION: begin
                    if (calibration_complete) begin
                        state <= STATE_FETCH_WRITE_BYTE;
                        beat_index <= 0;
                        byte_index <= 0;
                        timeout_counter <= 0;
                        status <= STATUS_WRITING;
                    end else if (timeout_counter >=
                                 CALIBRATION_TIMEOUT_CYCLES - 1) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_TIMEOUT;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                STATE_FETCH_WRITE_BYTE: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else begin
                        source_byte <= source_pixels[source_address];
                        state <= STATE_STORE_WRITE_BYTE;
                    end
                end

                STATE_STORE_WRITE_BYTE: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else begin
                        source_data[byte_index * 8 +: 8] <= source_byte;
                        if (byte_index == 5'd31) begin
                            byte_index <= 0;
                            state <= STATE_WRITE;
                        end else begin
                            byte_index <= byte_index + 1'b1;
                            state <= STATE_FETCH_WRITE_BYTE;
                        end
                    end
                end

                STATE_WRITE: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (write_pair_ready) begin
                        timeout_counter <= 0;
                        if (final_beat) begin
                            state <= STATE_WRITE_DRAIN;
                            beat_index <= 0;
                        end else begin
                            beat_index <= beat_index + 1'b1;
                            byte_index <= 0;
                            state <= STATE_FETCH_WRITE_BYTE;
                        end
                    end else if (timeout_counter >=
                                 TRANSACTION_TIMEOUT_CYCLES - 1) begin
                        state <= STATE_DONE;
                        status <= STATUS_TRANSACTION_TIMEOUT;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                STATE_WRITE_DRAIN: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (timeout_counter >=
                                 WRITE_DRAIN_CYCLES - 1) begin
                        state <= STATE_FETCH_READ_BYTE;
                        timeout_counter <= 0;
                        target_bank <= 0;
                        byte_index <= 0;
                        status <= STATUS_READING;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                STATE_FETCH_READ_BYTE: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else begin
                        source_byte <= source_pixels[source_address];
                        state <= STATE_STORE_READ_BYTE;
                    end
                end

                STATE_STORE_READ_BYTE: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else begin
                        source_data[byte_index * 8 +: 8] <= source_byte;
                        if (byte_index == 5'd31) begin
                            byte_index <= 0;
                            state <= STATE_READ_COMMAND;
                        end else begin
                            byte_index <= byte_index + 1'b1;
                            state <= STATE_FETCH_READ_BYTE;
                        end
                    end
                end

                STATE_READ_COMMAND: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (controller_command_ready) begin
                        state <= STATE_READ_RESPONSE;
                        timeout_counter <= 0;
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
                        buffer_write_enable <= 1'b1;
                        buffer_write_bank <= target_bank;
                        buffer_write_address <= beat_index;
                        buffer_write_data <= controller_read_data;
                        if (final_beat) begin
                            completion_bank <= target_bank;
                            completion_toggle <= ~completion_toggle;
                            logo_ready <= 1'b1;
                            status <= STATUS_PASS;
                            state <= STATE_WAIT_REQUEST;
                        end else begin
                            beat_index <= beat_index + 1'b1;
                            byte_index <= 0;
                            state <= STATE_FETCH_READ_BYTE;
                        end
                    end else if (timeout_counter >=
                                 TRANSACTION_TIMEOUT_CYCLES - 1) begin
                        state <= STATE_DONE;
                        status <= STATUS_TRANSACTION_TIMEOUT;
                    end else begin
                        timeout_counter <= timeout_counter + 1'b1;
                    end
                end

                STATE_WAIT_REQUEST: begin
                    if (!calibration_complete) begin
                        state <= STATE_DONE;
                        status <= STATUS_CALIBRATION_LOST;
                    end else if (reload_request_toggle != request_seen) begin
                        request_seen <= reload_request_toggle;
                        target_bank <= reload_request_bank;
                        beat_index <= 0;
                        byte_index <= 0;
                        timeout_counter <= 0;
                        status <= STATUS_READING;
                        state <= STATE_FETCH_READ_BYTE;
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
