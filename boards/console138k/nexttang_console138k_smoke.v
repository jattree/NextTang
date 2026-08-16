// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_console138k_smoke (
    input  wire       sys_clk,
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
        .red(red),
        .green(green),
        .blue(blue),
        .hsync(hsync),
        .vsync(vsync),
        .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

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
