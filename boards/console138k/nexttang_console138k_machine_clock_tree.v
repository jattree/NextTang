// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Complete Console 138K clock and reset boundary for the direct machine core.
// Reset asserts immediately if any prerequisite fails and releases in the
// 28 MHz domain only after the PLL and external memory are ready.
module nexttang_console138k_machine_clock_tree #(
    parameter integer RESET_RELEASE_STAGES = 4
) (
    input  wire       clock_27,
    input  wire       force_reset,
    input  wire       memory_calibrated,
    input  wire       memory_fault,
    input  wire       cpu_clock_lsb,
    input  wire       cpu_contend,
    input  wire [1:0] cpu_speed,
    output wire       clock_28,
    output wire       clock_28_n,
    output wire       clock_14,
    output wire       clock_7,
    output wire       clock_3m5,
    output wire       cpu_clock,
    output wire       psg_enable,
    output wire       machine_reset,
    output wire       clock_locked
);
    wire machine_reset_request = force_reset || !clock_locked ||
                                 !memory_calibrated || memory_fault;

    nexttang_console138k_machine_pll machine_pll (
        .clock_in(clock_27),
        .clock_28(clock_28),
        .clock_28_n(clock_28_n),
        .clock_14(clock_14),
        .clock_7(clock_7),
        .locked(clock_locked)
    );

    nexttang_reset_release #(.STAGES(RESET_RELEASE_STAGES)) reset_release (
        .clock(clock_28),
        .asynchronous_reset(machine_reset_request),
        .reset(machine_reset)
    );

    nexttang_cpu_clock_contention contention_clock (
        .clock_7(clock_7),
        .reset(machine_reset),
        .cpu_clock_lsb(cpu_clock_lsb),
        .cpu_contend(cpu_contend),
        .clock_3m5(clock_3m5)
    );

    nexttang_machine_clock_enables machine_enables (
        .clock_28(clock_28),
        .reset(machine_reset),
        .psg_enable(psg_enable)
    );

    nexttang_console138k_cpu_clock_mux cpu_clock_mux (
        .clock_3m5(clock_3m5),
        .clock_7(clock_7),
        .clock_14(clock_14),
        .clock_28(clock_28),
        .cpu_speed(cpu_speed),
        .cpu_clock(cpu_clock)
    );
endmodule

`default_nettype wire
