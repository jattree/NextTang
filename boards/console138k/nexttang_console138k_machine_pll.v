// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// 50 MHz input, 50 MHz PFD and 700 MHz VCO.  One phase-zero output divides the
// VCO by 25 for an exact 28 MHz, and a second divide-by-25 output is shifted by
// 180 degrees.  14 and 7 MHz are divided down from 28 in fabric rather than
// taken as further PLL outputs.
//
// They were PLL outputs, and the three clocks then landed on unrelated clock
// resources with 405 ps of skew between them, which broke hold timing inside
// the upstream ULA on its own 7 to 14 MHz paths.  Dividing from one source with
// one reset makes the relationship the constraints declare a real one.
//
// The 50 MHz board clock on V22 is used rather than the Dock's 27 MHz on V10,
// which has no clock-capable routing on this device.  Integer dividers reach
// the machine frequencies exactly from 50 MHz, so nothing is lost by it.

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
    wire unused_clock_one;
    wire unused_clock_two;
    wire unused_clock_four;
    wire unused_clock_five;
    wire unused_clock_six;
    wire unused_feedback;

    PLL pll (
        .LOCK(locked),
        .CLKOUT0(clock_28),
        .CLKOUT1(unused_clock_one),
        .CLKOUT2(unused_clock_two),
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

    defparam pll.FCLKIN = "50";
    defparam pll.IDIV_SEL = 1;
    defparam pll.FBDIV_SEL = 1;
    defparam pll.ODIV0_SEL = 25;
    defparam pll.ODIV1_SEL = 50;
    defparam pll.ODIV2_SEL = 100;
    defparam pll.ODIV3_SEL = 25;
    defparam pll.ODIV4_SEL = 8;
    defparam pll.ODIV5_SEL = 8;
    defparam pll.ODIV6_SEL = 8;
    defparam pll.MDIV_SEL = 14;
    defparam pll.MDIV_FRAC_SEL = 0;
    defparam pll.ODIV0_FRAC_SEL = 0;
    defparam pll.CLKOUT0_EN = "TRUE";
    defparam pll.CLKOUT1_EN = "FALSE";
    defparam pll.CLKOUT2_EN = "FALSE";
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

    // Both dividers take the same high speed clock and come out of the same
    // reset, so their counters start together and 7 MHz keeps a fixed phase
    // against 14 MHz. A CLKDIV output is not a valid HCLKIN, so 7 is divided
    // from 28 directly rather than chained off 14.
    CLKDIV #(.DIV_MODE("2")) divider_14 (
        .HCLKIN(clock_28),
        .RESETN(locked),
        .CALIB(1'b0),
        .CLKOUT(clock_14)
    );

    CLKDIV #(.DIV_MODE("4")) divider_7 (
        .HCLKIN(clock_28),
        .RESETN(locked),
        .CALIB(1'b0),
        .CLKOUT(clock_7)
    );
endmodule

`default_nettype wire
