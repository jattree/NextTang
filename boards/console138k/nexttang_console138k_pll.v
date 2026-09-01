// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// 50 MHz to an in-range 1125 MHz VCO, divided to a 375 MHz OSER10 serial clock
// and a 75 MHz pixel/HDMI clock.  The resulting 1650x750 raster is 60.61 Hz.
// A previous 2975 MHz VCO configuration asserted LOCK and displayed simpler
// screens, but repeatedly lost HDMI receiver synchronisation on Cybernoid.
// The 1125 MHz configuration removed that content-dependent failure in the
// bounded direct-monitor hardware test recorded in the LLMWiki.

`default_nettype none

// The pixel clock comes from the PLL's own second output rather than a CLKDIV
// of the serial clock. A divide by five cannot be even: a counter gives three
// cycles high and two low, so the pixel clock, and with it the HDMI clock lane
// that every receiver recovers timing from, sits at 60/40 against a 40 to 60
// per cent specification. Taking it from the PLL divider gives 50/50 and puts
// nothing in the path.
module nexttang_console138k_pll (
    input  wire clock_in,
    output wire serial_clock,
    output wire pixel_clock,
    output wire locked
);
    wire ground = 1'b0;
    wire power = 1'b1;
    wire unused_clock_two;
    wire unused_clock_three;
    wire unused_clock_four;
    wire unused_clock_five;
    wire unused_clock_six;
    wire unused_feedback;

    PLL pll (
        .LOCK(locked),
        .CLKOUT0(serial_clock),
        .CLKOUT1(pixel_clock),
        .CLKOUT2(unused_clock_two),
        .CLKOUT3(unused_clock_three),
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
    defparam pll.ODIV0_SEL = 3;
    defparam pll.ODIV1_SEL = 15;    // 1125 / 15 = 75 MHz, the pixel clock
    defparam pll.ODIV2_SEL = 3;
    defparam pll.ODIV3_SEL = 3;
    defparam pll.ODIV4_SEL = 3;
    defparam pll.ODIV5_SEL = 3;
    defparam pll.ODIV6_SEL = 3;
    defparam pll.MDIV_SEL = 22;
    defparam pll.MDIV_FRAC_SEL = 4;
    defparam pll.ODIV0_FRAC_SEL = 0;
    defparam pll.CLKOUT0_EN = "TRUE";
    defparam pll.CLKOUT1_EN = "TRUE";
    defparam pll.CLKOUT2_EN = "FALSE";
    defparam pll.CLKOUT3_EN = "FALSE";
    defparam pll.CLKOUT4_EN = "FALSE";
    defparam pll.CLKOUT5_EN = "FALSE";
    defparam pll.CLKOUT6_EN = "FALSE";
    defparam pll.CLKFB_SEL = "INTERNAL";
endmodule

`default_nettype wire
