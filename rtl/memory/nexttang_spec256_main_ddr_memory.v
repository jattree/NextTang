// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Spec256 ordinary 48K memory with the screen-visible 16K retained locally
// and 0x8000-0xffff served by the shared DDR3 byte/line path. During pack
// loading the main CPU is held reset, so loader and CPU requests are mutually
// exclusive by construction.
module nexttang_spec256_main_ddr_memory #(
    parameter integer MAX_WAIT_CYCLES = 1024
) (
    input  wire         cpu_clock,
    input  wire         path_reset,
    input  wire         memory_available,
    input  wire [15:0]  cpu_address,
    input  wire [7:0]   cpu_write_data,
    input  wire         cpu_mreq_n,
    input  wire         cpu_rd_n,
    input  wire         cpu_wr_n,
    input  wire         cpu_rfsh_n,
    output wire [7:0]   ram_read_data,
    output wire         cpu_wait_n,
    input  wire         loader_write,
    input  wire [15:0]  loader_address,
    input  wire [7:0]   loader_write_data,
    output wire         loader_upper_complete,
    input  wire         video_clock,
    input  wire [13:0]  video_address,
    output wire [7:0]   video_data,
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
    wire cpu_lower_selected = cpu_address[15:14] == 2'b01;
    wire cpu_upper_selected = cpu_address[15];
    wire cpu_cycle = !cpu_mreq_n && cpu_rfsh_n && (!cpu_rd_n || !cpu_wr_n);
    wire cpu_upper_request = cpu_cycle && cpu_upper_selected;
    wire loader_lower_write = loader_write &&
                              loader_address[15:14] == 2'b01;
    wire loader_upper_write = loader_write && loader_address[15];
    wire lower_write = loader_lower_write ||
                       (cpu_cycle && cpu_lower_selected && !cpu_wr_n);
    wire [15:0] selected_address = loader_write ? loader_address : cpu_address;
    wire [7:0] selected_write_data = loader_write ? loader_write_data :
                                                   cpu_write_data;
    wire selected_request = loader_upper_write || cpu_upper_request;
    wire selected_read_n = loader_upper_write ? 1'b1 : cpu_rd_n;
    wire [7:0] lower_read_data;
    wire [7:0] upper_read_data;
    wire upper_wait;
    wire upper_complete;

    nexttang_block_ram #(.ADDRESS_BITS(14)) lower_ram (
        .clock(cpu_clock), .write_enable(lower_write),
        .write_address(selected_address[13:0]),
        .write_data(selected_write_data), .read_data(lower_read_data),
        .port_b_clock(video_clock), .port_b_address(video_address),
        .port_b_data(video_data));

    nexttang_cpu_memory_path #(.MAX_WAIT_CYCLES(MAX_WAIT_CYCLES)) upper_memory (
        .machine_clock(cpu_clock), .machine_reset(path_reset),
        .memory_available(memory_available), .core_request(selected_request),
        .core_read_n(selected_read_n), .core_address({5'b0,selected_address}),
        .core_write_data(selected_write_data), .core_read_data(upper_read_data),
        .core_wait(upper_wait), .core_complete(upper_complete),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .line_request(line_request), .line_ready(line_ready),
        .line_write(line_write), .line_address(line_address),
        .line_write_data(line_write_data), .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid), .line_read_data(line_read_data),
        .fault_timeout(fault_timeout), .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost));

    assign ram_read_data = cpu_upper_selected ? upper_read_data : lower_read_data;
    assign cpu_wait_n = !cpu_upper_request || upper_complete;
    assign loader_upper_complete = upper_complete && loader_upper_write == 1'b0;
endmodule

`default_nettype wire
