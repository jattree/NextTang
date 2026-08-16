// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Portable CPU-to-line-memory path. The vendor DDR3 wrapper sits beyond the
// line interface and is responsible for controller-specific address and mask
// conventions.
module nexttang_cpu_memory_path #(
    parameter integer MAX_WAIT_CYCLES = 1024
) (
    input  wire         machine_clock,
    input  wire         machine_reset,
    input  wire         memory_available,

    input  wire         core_request,
    input  wire         core_read_n,
    input  wire [20:0]  core_address,
    input  wire [7:0]   core_write_data,
    output wire [7:0]   core_read_data,
    output wire         core_wait,
    output wire         core_complete,

    input  wire         memory_clock,
    input  wire         memory_reset,
    output wire         line_request,
    input  wire         line_ready,
    output wire         line_write,
    output wire [16:0]  line_address,
    output wire [127:0] line_write_data,
    output wire [15:0]  line_write_enable,
    input  wire         line_response_valid,
    input  wire [127:0] line_read_data,

    output wire         fault_timeout,
    output wire         fault_overrun,
    output wire         fault_calibration_lost
);
    wire service_request;
    wire service_ready;
    wire service_write;
    wire [20:0] service_address;
    wire [7:0] service_write_data;
    wire service_response_valid;
    wire [7:0] service_read_data;

    wire memory_byte_request;
    wire memory_byte_ready;
    wire memory_byte_write;
    wire [20:0] memory_byte_address;
    wire [7:0] memory_byte_write_data;
    wire memory_byte_response_valid;
    wire [7:0] memory_byte_read_data;

    nexttang_cpu_memory_service #(
        .MAX_WAIT_CYCLES(MAX_WAIT_CYCLES)
    ) service (
        .clock(machine_clock),
        .reset(machine_reset),
        .calibrated(memory_available),
        .core_request(core_request),
        .core_read_n(core_read_n),
        .core_address(core_address),
        .core_write_data(core_write_data),
        .core_read_data(core_read_data),
        .core_wait(core_wait),
        .core_complete(core_complete),
        .memory_request(service_request),
        .memory_ready(service_ready),
        .memory_write(service_write),
        .memory_address(service_address),
        .memory_write_data(service_write_data),
        .memory_response_valid(service_response_valid),
        .memory_read_data(service_read_data),
        .fault_timeout(fault_timeout),
        .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

    nexttang_memory_cdc_bridge clock_crossing (
        .source_clock(machine_clock),
        .source_reset(machine_reset),
        .source_request(service_request),
        .source_ready(service_ready),
        .source_write(service_write),
        .source_address(service_address),
        .source_write_data(service_write_data),
        .source_response_valid(service_response_valid),
        .source_read_data(service_read_data),
        .destination_clock(memory_clock),
        .destination_reset(memory_reset),
        .destination_request(memory_byte_request),
        .destination_ready(memory_byte_ready),
        .destination_write(memory_byte_write),
        .destination_address(memory_byte_address),
        .destination_write_data(memory_byte_write_data),
        .destination_response_valid(memory_byte_response_valid),
        .destination_read_data(memory_byte_read_data)
    );

    nexttang_byte_line_adapter line_adapter (
        .clock(memory_clock),
        .reset(memory_reset),
        .byte_request(memory_byte_request),
        .byte_ready(memory_byte_ready),
        .byte_write(memory_byte_write),
        .byte_address(memory_byte_address),
        .byte_write_data(memory_byte_write_data),
        .byte_response_valid(memory_byte_response_valid),
        .byte_read_data(memory_byte_read_data),
        .line_request(line_request),
        .line_ready(line_ready),
        .line_write(line_write),
        .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data)
    );
endmodule

`default_nettype wire
