// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_reset_tree #(
    parameter integer RELEASE_STAGES = 4
) (
    input  wire system_clock,
    input  wire machine_clock,
    input  wire pixel_clock,
    input  wire force_reset,
    input  wire system_clock_locked,
    input  wire machine_clock_locked,
    input  wire video_clock_locked,
    input  wire memory_calibrated,
    input  wire memory_fault,
    output wire system_reset,
    output wire machine_reset,
    output wire pixel_reset
);
    wire system_reset_request = force_reset || !system_clock_locked;
    wire machine_reset_request = force_reset || !machine_clock_locked ||
                                 !memory_calibrated || memory_fault;
    wire pixel_reset_request = force_reset || !video_clock_locked;

    nexttang_reset_release #(.STAGES(RELEASE_STAGES)) system_release (
        .clock(system_clock),
        .asynchronous_reset(system_reset_request),
        .reset(system_reset)
    );

    nexttang_reset_release #(.STAGES(RELEASE_STAGES)) machine_release (
        .clock(machine_clock),
        .asynchronous_reset(machine_reset_request),
        .reset(machine_reset)
    );

    nexttang_reset_release #(.STAGES(RELEASE_STAGES)) pixel_release (
        .clock(pixel_clock),
        .asynchronous_reset(pixel_reset_request),
        .reset(pixel_reset)
    );
endmodule

`default_nettype wire
