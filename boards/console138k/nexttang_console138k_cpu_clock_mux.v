// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Tang Console 138K implementation of the direct core's four-way CPU clock
// selection.  All four inputs must arrive on clock-capable routes.  The DCS
// primitive keeps clock selection on the GW5AST dedicated clock network.
module nexttang_console138k_cpu_clock_mux (
    input  wire       clock_3m5,
    input  wire       clock_7,
    input  wire       clock_14,
    input  wire       clock_28,
    input  wire [1:0] cpu_speed,
    output wire       cpu_clock
);
    wire [3:0] clock_select = 4'b0001 << cpu_speed;

    DCS #(.DCS_MODE("RISING")) cpu_clock_selector (
        .CLKOUT(cpu_clock),
        .CLKIN0(clock_3m5),
        .CLKIN1(clock_7),
        .CLKIN2(clock_14),
        .CLKIN3(clock_28),
        .CLKSEL(clock_select),
        .SELFORCE(1'b0)
    );
endmodule

`default_nettype wire
