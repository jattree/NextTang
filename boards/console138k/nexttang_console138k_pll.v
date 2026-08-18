// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// 50 MHz to 371.875 MHz, followed by CLKDIV / 5 in the board top level, giving
// a 74.375 MHz pixel clock and 60.10 Hz at the 1650x750 720p raster.
//
// The output divider is 8 and MDIV is 59.5 rather than the 2 and 14.875 that
// give the same 371.875 MHz from a much lower VCO. That is not a style choice.
// This device did not lock with the VCO at 743.75 MHz and does lock at
// 2975 MHz, measured by building both and looking at the screen: the low-VCO
// version produced no video at all while every other signal in the design was
// correct. 743.75 sits inside the 650 to 1300 MHz range the datasheet figures
// suggested, so that range does not describe this part. Raise MDIV and the
// output divider together if this frequency ever needs changing, and keep the
// VCO high.
//
// Exact 74.25 MHz is unreachable from this board's 50 MHz input: MDIV moves in
// eighths, so 0.17 per cent high is the closest this input reaches. 59.375
// lands nearer at 59.98 Hz and is worth revisiting, but 59.5 is the ratio with
// a confirmed picture.

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
    defparam pll.ODIV0_SEL = 8;
    defparam pll.ODIV1_SEL = 40;    // 2975 / 40 = 74.375 MHz, the pixel clock
    defparam pll.ODIV2_SEL = 8;
    defparam pll.ODIV3_SEL = 8;
    defparam pll.ODIV4_SEL = 8;
    defparam pll.ODIV5_SEL = 8;
    defparam pll.ODIV6_SEL = 8;
    defparam pll.MDIV_SEL = 59;
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
