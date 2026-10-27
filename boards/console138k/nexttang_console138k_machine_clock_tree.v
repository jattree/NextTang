// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Complete Console 138K clock and reset boundary for the direct machine core.
// Reset asserts immediately if any prerequisite fails and releases in the
// 28 MHz domain only after the PLL and external memory are ready.
//
// There is no CPU clock. The core's CPU runs on clock_28 with the enables from
// rtl/clock/nexttang_zxnext_cpu_enables.vhd. A CPU clock built here, from a
// fabric flip-flop through a speed-select DCS, reached the CPU about 2 ns after
// clock_28 reached the rest of the machine, by a route Gowin's tools neither
// analyse nor constrain, and broke hold timing on the CPU's I/O read-back.
module nexttang_console138k_machine_clock_tree #(
    parameter integer RESET_RELEASE_STAGES = 4
) (
    input  wire       clock_27,
    input  wire       force_reset,
    input  wire       memory_calibrated,
    input  wire       memory_fault,
    output wire       clock_28,
    output wire       clock_28_n,
    output wire       clock_14,
    output wire       clock_7,
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

    nexttang_machine_clock_enables machine_enables (
        .clock_28(clock_28),
        .reset(machine_reset),
        .psg_enable(psg_enable)
    );
endmodule

`default_nettype wire
