// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Connects the ZXNext core's main-memory port A to the portable CPU memory
// path.
//
// The core raises o_RAM_A_REQ2 for the whole of a memory cycle that reaches
// SRAM and expects i_CPU_WAIT, active high, to hold the CPU until data is
// ready, as MiSTer's SDRAM controller does on a cache miss. Wait is asserted
// combinationally from the request, so it is already high when the Z80 samples
// it in T2, and stays high until the transaction completes.
//
// The memory path runs on the 28 MHz machine clock and reports completion with
// a one-cycle pulse, while the CPU may run eight times slower. A sticky done
// flag keeps wait released from completion until the core ends the request;
// without it, wait would rise again after the pulse and hold the CPU forever.
//
// With CACHE set, nexttang_cpu_line_cache sits between the core and the path
// and answers most reads from block RAM in two cycles.
module nexttang_zxnext_memory_port #(
    parameter integer MAX_WAIT_CYCLES = 1024,
    parameter integer CACHE = 0
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
    wire path_complete;
    wire [7:0] path_read_data;
    wire [127:0] path_read_line;
    wire path_request;
    wire path_read_n;
    wire [20:0] path_address;
    wire [7:0] path_write_data;

    generate
        if (CACHE != 0) begin : cached
            nexttang_cpu_line_cache cache (
                .clock(machine_clock),
                .memory_available(memory_available),
                .core_request(core_request),
                .core_read_n(core_read_n),
                .core_address(core_address),
                .core_write_data(core_write_data),
                .core_read_data(core_read_data),
                .core_wait(core_wait),
                .down_request(path_request),
                .down_read_n(path_read_n),
                .down_address(path_address),
                .down_write_data(path_write_data),
                .down_complete(path_complete),
                .down_read_line(path_read_line)
            );
        end else begin : direct
            reg done = 1'b0;

            always @(posedge machine_clock or posedge machine_reset) begin
                if (machine_reset)
                    done <= 1'b0;
                else if (!core_request)
                    done <= 1'b0;
                else if (path_complete)
                    done <= 1'b1;
            end

            assign core_wait = !memory_available || (core_request && !done);
            assign core_read_data = path_read_data;
            assign path_request = core_request;
            assign path_read_n = core_read_n;
            assign path_address = core_address;
            assign path_write_data = core_write_data;
        end
    endgenerate

    nexttang_cpu_memory_path #(
        .MAX_WAIT_CYCLES(MAX_WAIT_CYCLES)
    ) path (
        .machine_clock(machine_clock),
        .machine_reset(machine_reset),
        .memory_available(memory_available),
        .core_request(path_request),
        .core_read_n(path_read_n),
        .core_address(path_address),
        .core_write_data(path_write_data),
        .core_read_data(path_read_data),
        .core_read_line(path_read_line),
        .core_wait(),
        .core_complete(path_complete),
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
endmodule

`default_nettype wire
