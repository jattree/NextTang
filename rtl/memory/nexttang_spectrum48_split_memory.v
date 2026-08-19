// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// First external-memory boundary for the 48K machine. The ULA-visible lower
// 16K remains dual-port block RAM for deterministic display access; contention
// itself is not implemented yet. Only the upper 32K crosses to the DDR3
// service. A later banked-memory implementation can replace the address mapping
// without changing the CPU or ULA interfaces.
module nexttang_spectrum48_split_memory #(
    parameter integer MAX_WAIT_CYCLES = 1024
) (
    input  wire         cpu_clock,
    input  wire         cpu_reset,
    input  wire         memory_available,
    input  wire [15:0]  cpu_address,
    input  wire [7:0]   cpu_write_data,
    input  wire         cpu_mreq_n,
    input  wire         cpu_rd_n,
    input  wire         cpu_wr_n,
    input  wire         cpu_rfsh_n,
    output wire [7:0]   ram_read_data,
    output wire         cpu_wait_n,
    output wire         upper_transaction_complete,

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
    wire lower_selected = cpu_address[15:14] == 2'b01;
    wire upper_selected = cpu_address[15];
    wire memory_cycle = !cpu_mreq_n && cpu_rfsh_n &&
                        (!cpu_rd_n || !cpu_wr_n);
    wire upper_request = memory_cycle && upper_selected;
    wire lower_write = memory_cycle && lower_selected && !cpu_wr_n;

    wire [7:0] lower_read_data;
    wire [7:0] upper_read_data;
    wire upper_wait;

    nexttang_block_ram #(.ADDRESS_BITS(14)) lower_ram (
        .clock(cpu_clock),
        .write_enable(lower_write),
        .write_address(cpu_address[13:0]),
        .write_data(cpu_write_data),
        .read_data(lower_read_data),
        .port_b_clock(video_clock),
        .port_b_address(video_address),
        .port_b_data(video_data)
    );

    nexttang_cpu_memory_path #(
        .MAX_WAIT_CYCLES(MAX_WAIT_CYCLES)
    ) upper_memory (
        .machine_clock(cpu_clock),
        .machine_reset(cpu_reset),
        .memory_available(memory_available),
        .core_request(upper_request),
        .core_read_n(cpu_rd_n),
        .core_address({5'b00000, cpu_address}),
        .core_write_data(cpu_write_data),
        .core_read_data(upper_read_data),
        .core_wait(upper_wait),
        .core_complete(upper_transaction_complete),
        .memory_clock(memory_clock),
        .memory_reset(memory_reset),
        .line_request(line_request),
        .line_ready(line_ready),
        .line_write(line_write),
        .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .fault_timeout(fault_timeout),
        .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

    assign ram_read_data = upper_selected
        ? upper_read_data : lower_read_data;

    // Assert WAIT in the same cycle that the CPU presents an upper-memory
    // request. Waiting only after the service has left IDLE is one cycle too
    // late: the Z80 can advance before the request has crossed to DDR3.
    // Completion releases exactly the transaction whose bus values are still
    // being held by the processor.
    assign cpu_wait_n = !upper_request || upper_transaction_complete;
endmodule

`default_nettype wire
