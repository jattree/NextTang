// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Portable adapter around the Gowin-generated DDR3 PLL wrapper. Gowin_PLL,
// its PLL_INIT sequencer and the primitive configuration are generated locally
// with the vendor tool and deliberately remain outside Git.
module nexttang_console138k_ddr3_pll (
    input  wire clock_in,
    input  wire clock_enable,
    output wire memory_clock,
    output wire reference_clock,
    output wire locked
);
    wire unused_clock;

    Gowin_PLL reference_pll (
        .clkin(clock_in),
        .init_clk(clock_in),
        .enclk0(1'b1),
        .enclk1(1'b1),
        .enclk2(clock_enable),
        .clkout0(unused_clock),
        .clkout1(reference_clock),
        .clkout2(memory_clock),
        .lock(locked),
        .reset(1'b0)
    );
endmodule

`default_nettype wire
