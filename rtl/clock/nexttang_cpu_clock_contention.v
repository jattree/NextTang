// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Reproduces the 3.5 MHz CPU clock hold contract exposed by the direct core.
// The 7 MHz input must be a dedicated clock source.  This module deliberately
// does not derive the faster machine clocks in fabric.
module nexttang_cpu_clock_contention (
    input  wire clock_7,
    input  wire reset,
    input  wire cpu_clock_lsb,
    input  wire cpu_contend,
    output reg  clock_3m5 = 1'b0
);
    always @(posedge clock_7 or posedge reset) begin
        if (reset)
            clock_3m5 <= 1'b0;
        else if (!cpu_clock_lsb)
            clock_3m5 <= 1'b1;
        else if (!cpu_contend)
            clock_3m5 <= 1'b0;
    end
endmodule

`default_nettype wire
