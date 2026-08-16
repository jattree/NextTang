// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Clock-enable cadence required by the direct ZX Spectrum Next core.  These
// are enables in the 28 MHz domain, not generated clocks.
module nexttang_machine_clock_enables (
    input  wire clock_28,
    input  wire reset,
    output wire psg_enable
);
    reg [3:0] divider = 4'b0000;

    always @(posedge clock_28 or posedge reset) begin
        if (reset)
            divider <= 4'b0000;
        else
            divider <= divider + 1'b1;
    end

    assign psg_enable = divider == 4'b1110;
endmodule

`default_nettype wire
