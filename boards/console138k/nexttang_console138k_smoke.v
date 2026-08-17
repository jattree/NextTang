// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_console138k_smoke (
    input  wire       sys_clk,
    input  wire       usr_clk,
    output wire       UART_TXD,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    wire serial_clock;
    wire pixel_clock;
    wire pll_locked;
    reg [3:0] pixel_reset_shift = 0;
    reg [3:0] system_reset_shift = 0;
    wire pixel_reset = !pixel_reset_shift[3];
    wire system_reset = !system_reset_shift[3];

    wire [7:0] pattern_red;
    wire [7:0] pattern_green;
    wire [7:0] pattern_blue;
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;
    wire hsync;
    wire vsync;
    wire data_enable;
    wire [10:0] horizontal_position;
    wire [9:0] vertical_position;
    wire [9:0] red_symbol;
    wire [9:0] green_symbol;
    wire [9:0] blue_symbol;
    wire [2:0] serial_data;

    nexttang_console138k_pll video_pll (
        .clock_in(sys_clk),
        .serial_clock(serial_clock),
        .locked(pll_locked)
    );

    CLKDIV #(.DIV_MODE(5)) pixel_clock_divider (
        .HCLKIN(serial_clock),
        .RESETN(pll_locked),
        .CALIB(1'b0),
        .CLKOUT(pixel_clock)
    );

    always @(posedge pixel_clock or negedge pll_locked) begin
        if (!pll_locked)
            pixel_reset_shift <= 0;
        else
            pixel_reset_shift <= {pixel_reset_shift[2:0], 1'b1};
    end

    always @(posedge sys_clk or negedge pll_locked) begin
        if (!pll_locked)
            system_reset_shift <= 0;
        else
            system_reset_shift <= {system_reset_shift[2:0], 1'b1};
    end

    nexttang_video_pattern #(
        .LOGO_FILE("nexttang_logo_128x128_rgb332.mem")
    ) pattern (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .red(pattern_red),
        .green(pattern_green),
        .blue(pattern_blue),
        .hsync(hsync),
        .vsync(vsync),
        .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    // Measures the Dock's MS5351 reference on V10 while the video path keeps
    // running from the 50 MHz board clock, so the answer does not depend on the
    // clock being measured.  Reported as a colour band across the top of the
    // screen: red no clock, green 27 MHz, blue 50 MHz, white some other rate,
    // black not yet measured.  The rest of the screen stays as the usual
    // pattern, which is the evidence that video itself is alive.
    // Three bands across the top of the screen, top to bottom:
    //   1. the Dock's MS5351 reference on V10, expected green at 27 MHz;
    //   2. the board clock, a control that must read blue at 50 MHz, so a
    //      result in band 1 cannot be confused with a probe that does not work;
    //   3. the refresh rate actually being generated, expected green near 60 Hz.
    wire [2:0] probe_colour;
    wire [2:0] control_colour;

    nexttang_clock_probe #(
        .CLOCK_HZ(50000000),
        .EXPECT_A_HZ(27000000),
        .EXPECT_B_HZ(50000000)
    ) clock_probe (
        .clock(sys_clk),
        .reset(system_reset),
        .measured_clock(usr_clk),
        .measured_hz(),
        .measured_valid(),
        .colour(probe_colour)
    );

    nexttang_clock_probe #(
        .CLOCK_HZ(50000000),
        .EXPECT_A_HZ(27000000),
        .EXPECT_B_HZ(50000000)
    ) control_probe (
        .clock(sys_clk),
        .reset(system_reset),
        .measured_clock(sys_clk),
        .measured_hz(),
        .measured_valid(),
        .colour(control_colour)
    );

    // The results change at most once a second, so a plain two-flop
    // synchroniser is enough; a bit of skew costs at most one wrong frame.
    // Fourth band: the refresh rate this design is actually generating, by
    // counting vsync edges against the board clock.  Sampled rather than used
    // as a clock, so no extra clock domain is created.
    wire [2:0] refresh_colour;

    nexttang_clock_probe #(
        .CLOCK_HZ(50000000),
        .EXPECT_A_HZ(60),
        .EXPECT_B_HZ(50),
        .TOLERANCE_DIV(10),
        .MEASURE_BY_SAMPLING(1)
    ) refresh_probe (
        .clock(sys_clk),
        .reset(system_reset),
        .measured_clock(vsync),
        .measured_hz(),
        .measured_valid(),
        .colour(refresh_colour)
    );

    reg [8:0] probe_colour_meta = 9'b0;
    reg [8:0] probe_colour_pixel = 9'b0;

    always @(posedge pixel_clock) begin
        probe_colour_meta <= {refresh_colour, control_colour, probe_colour};
        probe_colour_pixel <= probe_colour_meta;
    end

    wire in_probe_band = (vertical_position < 10'd90);
    wire in_control_band = (vertical_position >= 10'd90) &&
                           (vertical_position < 10'd180);
    wire in_refresh_band = (vertical_position >= 10'd180) &&
                           (vertical_position < 10'd270);
    wire [2:0] band_colour = in_probe_band   ? probe_colour_pixel[2:0] :
                             in_control_band ? probe_colour_pixel[5:3] :
                                               probe_colour_pixel[8:6];
    wire in_any_band = in_probe_band || in_control_band || in_refresh_band;

    assign red = in_any_band ? {8{band_colour[2]}} : pattern_red;
    assign green = in_any_band ? {8{band_colour[1]}} : pattern_green;
    assign blue = in_any_band ? {8{band_colour[0]}} : pattern_blue;

    nexttang_tmds_encoder blue_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(blue), .control_zero(hsync), .control_one(vsync),
        .data_enable(data_enable), .symbol(blue_symbol)
    );
    nexttang_tmds_encoder green_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(green), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(green_symbol)
    );
    nexttang_tmds_encoder red_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(red), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(red_symbol)
    );

    OSER10 blue_serializer (
        .D0(blue_symbol[0]), .D1(blue_symbol[1]),
        .D2(blue_symbol[2]), .D3(blue_symbol[3]),
        .D4(blue_symbol[4]), .D5(blue_symbol[5]),
        .D6(blue_symbol[6]), .D7(blue_symbol[7]),
        .D8(blue_symbol[8]), .D9(blue_symbol[9]),
        .PCLK(pixel_clock), .FCLK(serial_clock),
        .RESET(1'b0), .Q(serial_data[0])
    );
    OSER10 green_serializer (
        .D0(green_symbol[0]), .D1(green_symbol[1]),
        .D2(green_symbol[2]), .D3(green_symbol[3]),
        .D4(green_symbol[4]), .D5(green_symbol[5]),
        .D6(green_symbol[6]), .D7(green_symbol[7]),
        .D8(green_symbol[8]), .D9(green_symbol[9]),
        .PCLK(pixel_clock), .FCLK(serial_clock),
        .RESET(1'b0), .Q(serial_data[1])
    );
    OSER10 red_serializer (
        .D0(red_symbol[0]), .D1(red_symbol[1]),
        .D2(red_symbol[2]), .D3(red_symbol[3]),
        .D4(red_symbol[4]), .D5(red_symbol[5]),
        .D6(red_symbol[6]), .D7(red_symbol[7]),
        .D8(red_symbol[8]), .D9(red_symbol[9]),
        .PCLK(pixel_clock), .FCLK(serial_clock),
        .RESET(1'b0), .Q(serial_data[2])
    );

    ELVDS_OBUF clock_output (
        .I(pixel_clock), .O(tmds_clk_p), .OB(tmds_clk_n)
    );
    ELVDS_OBUF data_output_zero (
        .I(serial_data[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0])
    );
    ELVDS_OBUF data_output_one (
        .I(serial_data[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1])
    );
    ELVDS_OBUF data_output_two (
        .I(serial_data[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2])
    );

    nexttang_uart_heartbeat heartbeat (
        .clock(sys_clk),
        .reset(system_reset),
        .transmit(UART_TXD)
    );
endmodule

`default_nettype wire
