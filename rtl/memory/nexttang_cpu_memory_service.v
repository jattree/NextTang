// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_cpu_memory_service #(
    parameter integer MAX_WAIT_CYCLES = 1024
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        calibrated,

    input  wire        core_request,
    input  wire        core_read_n,
    input  wire [20:0] core_address,
    input  wire [7:0]  core_write_data,
    output reg  [7:0]  core_read_data,
    output wire        core_wait,
    output reg         core_complete,

    output reg         memory_request,
    input  wire        memory_ready,
    output reg         memory_write,
    output reg  [20:0] memory_address,
    output reg  [7:0]  memory_write_data,
    input  wire        memory_response_valid,
    input  wire [7:0]  memory_read_data,

    output reg         fault_timeout,
    output reg         fault_overrun,
    output reg         fault_calibration_lost
);
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_ISSUE = 2'd1;
    localparam [1:0] STATE_RESPONSE = 2'd2;
    localparam [1:0] STATE_FAULT = 2'd3;

    reg [1:0] state;
    reg [31:0] wait_cycles;
    reg previous_core_request;

    wire new_core_request = core_request && !previous_core_request;

    assign core_wait = !calibrated || state != STATE_IDLE;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            wait_cycles <= 0;
            previous_core_request <= 1'b0;
            core_read_data <= 0;
            core_complete <= 1'b0;
            memory_request <= 1'b0;
            memory_write <= 1'b0;
            memory_address <= 0;
            memory_write_data <= 0;
            fault_timeout <= 1'b0;
            fault_overrun <= 1'b0;
            fault_calibration_lost <= 1'b0;
        end else begin
            previous_core_request <= core_request;
            core_complete <= 1'b0;

            if (!calibrated && state != STATE_IDLE) begin
                state <= STATE_FAULT;
                memory_request <= 1'b0;
                fault_calibration_lost <= 1'b1;
            end else begin
                case (state)
                    STATE_IDLE: begin
                        wait_cycles <= 0;
                        memory_request <= 1'b0;
                        if (calibrated && new_core_request) begin
                            memory_address <= core_address;
                            memory_write <= core_read_n;
                            memory_write_data <= core_write_data;
                            memory_request <= 1'b1;
                            state <= STATE_ISSUE;
                        end
                    end

                    STATE_ISSUE: begin
                        if (new_core_request)
                            fault_overrun <= 1'b1;

                        if (memory_ready) begin
                            memory_request <= 1'b0;
                            wait_cycles <= wait_cycles + 1'b1;
                            if (memory_response_valid) begin
                                if (!memory_write)
                                    core_read_data <= memory_read_data;
                                core_complete <= 1'b1;
                                state <= STATE_IDLE;
                            end else begin
                                state <= STATE_RESPONSE;
                            end
                        end else if (wait_cycles + 1 >= MAX_WAIT_CYCLES) begin
                            memory_request <= 1'b0;
                            fault_timeout <= 1'b1;
                            state <= STATE_FAULT;
                        end else begin
                            wait_cycles <= wait_cycles + 1'b1;
                        end
                    end

                    STATE_RESPONSE: begin
                        if (new_core_request)
                            fault_overrun <= 1'b1;

                        if (memory_response_valid) begin
                            if (!memory_write)
                                core_read_data <= memory_read_data;
                            core_complete <= 1'b1;
                            state <= STATE_IDLE;
                        end else if (wait_cycles + 1 >= MAX_WAIT_CYCLES) begin
                            fault_timeout <= 1'b1;
                            state <= STATE_FAULT;
                        end else begin
                            wait_cycles <= wait_cycles + 1'b1;
                        end
                    end

                    default: begin
                        memory_request <= 1'b0;
                        state <= STATE_FAULT;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
