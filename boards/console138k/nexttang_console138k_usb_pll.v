// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Exact 60 MHz USB host clock from the Console's 50 MHz oscillator. The PLL
// runs at 1200 MHz and divides by 20. The full-speed host divides this for
// low-speed devices. This is handwritten primitive wiring rather than
// redistributed Gowin-generated IP.

`default_nettype none

module nexttang_console138k_usb_pll (
    input  wire clock_in,
    output wire clock_60,
    output wire locked
);
    wire ground = 1'b0;
    wire power = 1'b1;
    wire unused_clock_one, unused_clock_two, unused_clock_three;
    wire unused_clock_four, unused_clock_five, unused_clock_six;
    wire unused_feedback;

    PLL pll (
        .LOCK(locked), .CLKOUT0(clock_60),
        .CLKOUT1(unused_clock_one), .CLKOUT2(unused_clock_two),
        .CLKOUT3(unused_clock_three), .CLKOUT4(unused_clock_four),
        .CLKOUT5(unused_clock_five), .CLKOUT6(unused_clock_six),
        .CLKFBOUT(unused_feedback), .CLKIN(clock_in), .CLKFB(ground),
        .RESET(ground), .PLLPWD(ground), .RESET_I(ground), .RESET_O(ground),
        .FBDSEL(6'b0), .IDSEL(6'b0), .MDSEL(7'b0), .MDSEL_FRAC(3'b0),
        .ODSEL0(7'b0), .ODSEL0_FRAC(3'b0), .ODSEL1(7'b0),
        .ODSEL2(7'b0), .ODSEL3(7'b0), .ODSEL4(7'b0),
        .ODSEL5(7'b0), .ODSEL6(7'b0),
        .DT0(4'b0), .DT1(4'b0), .DT2(4'b0), .DT3(4'b0),
        .ICPSEL(6'b0), .LPFRES(3'b0), .LPFCAP(2'b0),
        .PSSEL(3'b0), .PSDIR(ground), .PSPULSE(ground),
        .ENCLK0(power), .ENCLK1(power), .ENCLK2(power), .ENCLK3(power),
        .ENCLK4(power), .ENCLK5(power), .ENCLK6(power),
        .SSCPOL(ground), .SSCON(ground), .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0)
    );

    defparam pll.FCLKIN = "50";
    defparam pll.IDIV_SEL = 1;
    defparam pll.FBDIV_SEL = 1;
    defparam pll.MDIV_SEL = 24;
    defparam pll.MDIV_FRAC_SEL = 0;
    defparam pll.ODIV0_SEL = 20;
    defparam pll.ODIV0_FRAC_SEL = 0;
    defparam pll.ODIV1_SEL = 8;
    defparam pll.ODIV2_SEL = 8;
    defparam pll.ODIV3_SEL = 8;
    defparam pll.ODIV4_SEL = 8;
    defparam pll.ODIV5_SEL = 8;
    defparam pll.ODIV6_SEL = 8;
    defparam pll.CLKOUT0_EN = "TRUE";
    defparam pll.CLKOUT1_EN = "FALSE";
    defparam pll.CLKOUT2_EN = "FALSE";
    defparam pll.CLKOUT3_EN = "FALSE";
    defparam pll.CLKOUT4_EN = "FALSE";
    defparam pll.CLKOUT5_EN = "FALSE";
    defparam pll.CLKOUT6_EN = "FALSE";
    defparam pll.CLKFB_SEL = "INTERNAL";
    defparam pll.DYN_DPA_EN = "FALSE";
endmodule

`default_nettype wire
