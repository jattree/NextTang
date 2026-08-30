// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Banked Spectrum 128K memory boundary for the Console 138K.  The two banks
// that can feed the ULA (5 and 7) remain dual-port BSRAM; the other six banks
// use the already-proven byte-to-line DDR3 transaction path.  CPU-visible
// aliases of banks 5 and 7 always reach the same local storage.
module nexttang_spectrum128_memory #(
    parameter integer MAX_WAIT_CYCLES = 1024
) (
    input  wire         cpu_clock,
    input  wire         cpu_reset,
    input  wire         memory_available,
    input  wire [15:0]  cpu_address,
    input  wire [2:0]   cpu_bank,
    input  wire [7:0]   cpu_write_data,
    input  wire         cpu_mreq_n,
    input  wire         cpu_rd_n,
    input  wire         cpu_wr_n,
    input  wire         cpu_rfsh_n,
    output wire [7:0]   ram_read_data,
    output wire         cpu_wait_n,
    output wire         transaction_complete,

    input  wire         video_clock,
    input  wire         video_bank,
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
    wire memory_cycle = !cpu_mreq_n && cpu_rfsh_n &&
                        (!cpu_rd_n || !cpu_wr_n);
    wire bank_5_selected = cpu_bank == 3'd5;
    wire bank_7_selected = cpu_bank == 3'd7;
    wire local_selected = bank_5_selected || bank_7_selected;
    wire external_request = memory_cycle && !local_selected;

    wire [7:0] bank_5_data;
    wire [7:0] bank_7_data;
    wire [7:0] external_data;
    wire external_wait;
    wire [7:0] bank_5_video;
    wire [7:0] bank_7_video;

    nexttang_block_ram #(.ADDRESS_BITS(14)) bank_5 (
        .clock(cpu_clock),
        .write_enable(memory_cycle && !cpu_wr_n && bank_5_selected),
        .write_address(cpu_address[13:0]),
        .write_data(cpu_write_data),
        .read_data(bank_5_data),
        .port_b_clock(video_clock),
        .port_b_address(video_address),
        .port_b_data(bank_5_video)
    );

    nexttang_block_ram #(.ADDRESS_BITS(14)) bank_7 (
        .clock(cpu_clock),
        .write_enable(memory_cycle && !cpu_wr_n && bank_7_selected),
        .write_address(cpu_address[13:0]),
        .write_data(cpu_write_data),
        .read_data(bank_7_data),
        .port_b_clock(video_clock),
        .port_b_address(video_address),
        .port_b_data(bank_7_video)
    );

    nexttang_cpu_memory_path #(
        .MAX_WAIT_CYCLES(MAX_WAIT_CYCLES)
    ) external_memory (
        .machine_clock(cpu_clock),
        .machine_reset(cpu_reset),
        .memory_available(memory_available),
        .core_request(external_request),
        .core_read_n(cpu_rd_n),
        .core_address({4'b0000, cpu_bank, cpu_address[13:0]}),
        .core_write_data(cpu_write_data),
        .core_read_data(external_data),
        .core_wait(external_wait),
        .core_complete(transaction_complete),
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

    assign ram_read_data = bank_5_selected ? bank_5_data :
                           bank_7_selected ? bank_7_data : external_data;
    assign video_data = video_bank ? bank_7_video : bank_5_video;
    assign cpu_wait_n = !external_request || transaction_complete;
endmodule

`default_nettype wire
