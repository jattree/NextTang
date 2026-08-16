// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// 27 MHz input, 27 MHz PFD and 756 MHz VCO.  Three phase-zero outputs
// divide the common VCO by 27, 54 and 108 for exact 28, 14 and 7 MHz
// machine clocks.  A fourth divide-by-27 output is shifted by 180 degrees.

`default_nettype none

module nexttang_console138k_machine_pll (
    input  wire clock_in,
    output wire clock_28,
    output wire clock_28_n,
    output wire clock_14,
    output wire clock_7,
    output wire locked
);
    wire ground = 1'b0;
    wire power = 1'b1;
    wire unused_clock_four;
    wire unused_clock_five;
    wire unused_clock_six;
    wire unused_feedback;

    PLL pll (
        .LOCK(locked),
        .CLKOUT0(clock_28),
        .CLKOUT1(clock_14),
        .CLKOUT2(clock_7),
        .CLKOUT3(clock_28_n),
        .CLKOUT4(unused_clock_four),
        .CLKOUT5(unused_clock_five),
        .CLKOUT6(unused_clock_six),
        .CLKFBOUT(unused_feedback),
        .CLKIN(clock_in),
        .CLKFB(ground),
        .RESET(ground),
        .PLLPWD(ground),
        .RESET_I(ground),
        .RESET_O(ground),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .MDSEL(7'b0),
        .MDSEL_FRAC(3'b0),
        .ODSEL0(7'b0),
        .ODSEL0_FRAC(3'b0),
        .ODSEL1(7'b0),
        .ODSEL2(7'b0),
        .ODSEL3(7'b0),
        .ODSEL4(7'b0),
        .ODSEL5(7'b0),
        .ODSEL6(7'b0),
        .DT0(4'b0),
        .DT1(4'b0),
        .DT2(4'b0),
        .DT3(4'b0),
        .ICPSEL(6'b0),
        .LPFRES(3'b0),
        .LPFCAP(2'b0),
        .PSSEL(3'b0),
        .PSDIR(ground),
        .PSPULSE(ground),
        .ENCLK0(power),
        .ENCLK1(power),
        .ENCLK2(power),
        .ENCLK3(power),
        .ENCLK4(power),
        .ENCLK5(power),
        .ENCLK6(power),
        .SSCPOL(ground),
        .SSCON(ground),
        .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0)
    );

    defparam pll.FCLKIN = "27";
    defparam pll.IDIV_SEL = 1;
    defparam pll.FBDIV_SEL = 1;
    defparam pll.ODIV0_SEL = 27;
    defparam pll.ODIV1_SEL = 54;
    defparam pll.ODIV2_SEL = 108;
    defparam pll.ODIV3_SEL = 27;
    defparam pll.ODIV4_SEL = 8;
    defparam pll.ODIV5_SEL = 8;
    defparam pll.ODIV6_SEL = 8;
    defparam pll.MDIV_SEL = 28;
    defparam pll.MDIV_FRAC_SEL = 0;
    defparam pll.ODIV0_FRAC_SEL = 0;
    defparam pll.CLKOUT0_EN = "TRUE";
    defparam pll.CLKOUT1_EN = "TRUE";
    defparam pll.CLKOUT2_EN = "TRUE";
    defparam pll.CLKOUT3_EN = "TRUE";
    defparam pll.CLKOUT4_EN = "FALSE";
    defparam pll.CLKOUT5_EN = "FALSE";
    defparam pll.CLKOUT6_EN = "FALSE";
    defparam pll.CLKFB_SEL = "INTERNAL";
    defparam pll.DYN_DPA_EN = "FALSE";
    defparam pll.CLKOUT0_PE_COARSE = 0;
    defparam pll.CLKOUT0_PE_FINE = 0;
    defparam pll.CLKOUT1_PE_COARSE = 0;
    defparam pll.CLKOUT1_PE_FINE = 0;
    defparam pll.CLKOUT2_PE_COARSE = 0;
    defparam pll.CLKOUT2_PE_FINE = 0;
    defparam pll.CLKOUT3_PE_COARSE = 13;
    defparam pll.CLKOUT3_PE_FINE = 4;
endmodule

`default_nettype wire
