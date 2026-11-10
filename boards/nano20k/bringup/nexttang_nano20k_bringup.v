// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Tang Nano 20K bring-up, step 1: clocks and HDMI.
//
// Not the Next. A board check for the shell's pins and clocking before the
// machine goes on: an rPLL takes the 27 MHz crystal to 135 MHz, CLKDIV makes
// the 27 MHz pixel clock, and the hdl-util transmitter sends 720x576p50
// (CEA VIC 17) through the GW2A serializer shim and ELVDS_OBUF, the same
// transport the Console uses. The picture is eight colour bars, a white
// border one pixel in from the edge, and a square that moves one pixel per
// frame, so a frozen picture is visible at a glance. The square in the
// top-left corner shows S1 (red) and S2 (green) as read, so the buttons'
// polarity can be seen on the screen.
//
// Step 2 adds the SDRAM self-test (nexttang_nano20k_sdram_test.v, 81 MHz)
// as a panel at the bottom: left half capture A, right half capture B;
// dark = not initialised, grey = first pass running, green = passes with no
// errors, red = errors. Inside the panel: the pass count in binary (white
// squares) and each capture's error count in binary (red squares).
// LEDs (lit when driven low): 0 video PLL lock, 1 1 Hz blink, 2 SDRAM PLL
// lock, 3 SDRAM initialised, 4 capture A clean, 5 capture B clean.
//
// The later steps add an SDRAM self-test, then the machine.

`default_nettype none

module nexttang_nano20k_bringup (
    input  wire       clock_27,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    input  wire [1:0] button,
    output wire [5:0] led,

    // in-package SDR SDRAM (bound by name, no pins)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);
    wire serial_clock;  // 135 MHz
    wire pixel_clock;   // 27 MHz
    wire pll_lock;

    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW2AR-18C"),
        .IDIV_SEL(0),       // 27 / 1
        .FBDIV_SEL(4),      // x 5 = 135 MHz
        .ODIV_SEL(4),       // VCO 540 MHz
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) serial_pll (
        .CLKIN(clock_27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(serial_clock), .LOCK(pll_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3()
    );

    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) pixel_divider (
        .HCLKIN(serial_clock), .RESETN(pll_lock), .CALIB(1'b0), .CLKOUT(pixel_clock)
    );

    // step 2: SDRAM clock, 27 x 3 = 81 MHz (VCO 648 MHz)
    wire sdram_clock, sdram_lock;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"),
        .IDIV_SEL(0), .FBDIV_SEL(2), .ODIV_SEL(8),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT")
    ) sdram_pll (
        .CLKIN(clock_27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(sdram_clock), .LOCK(sdram_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3()
    );
    reg [7:0] sdram_reset_count = 8'd0;
    always @(posedge sdram_clock or negedge sdram_lock)
        if (!sdram_lock) sdram_reset_count <= 8'd0;
        else if (!sdram_reset_count[7]) sdram_reset_count <= sdram_reset_count + 8'd1;

    wire [15:0] sd_passes; wire [23:0] sd_errors_a, sd_errors_b; wire sd_init_done, sd_reading;
    nexttang_nano20k_sdram_test #(.CLOCK_HZ(81_000_000)) sdram_test (
        .clock(sdram_clock), .reset(!sdram_reset_count[7]),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba), .O_sdram_dqm(O_sdram_dqm),
        .IO_sdram_dq(IO_sdram_dq),
        .passes(sd_passes), .errors_a(sd_errors_a), .errors_b(sd_errors_b),
        .init_done(sd_init_done), .reading(sd_reading)
    );

    // reset held until the PLL has been locked for a while
    reg [7:0] reset_count = 8'd0;
    always @(posedge pixel_clock or negedge pll_lock)
        if (!pll_lock) reset_count <= 8'd0;
        else if (!reset_count[7]) reset_count <= reset_count + 8'd1;
    wire pixel_reset = !reset_count[7];

    wire [11:0] cx;
    wire [9:0]  cy;
    reg  [23:0] rgb;
    wire [2:0] serial_data;
    wire serial_tmds_clock;

    hdmi #(
        .VIDEO_ID_CODE(17),
        .DVI_OUTPUT(1'b1),   // step 1: video only (no audio, so no data islands)
        .VIDEO_REFRESH_RATE(50.0),
        .AUDIO_RATE(48000),
        .AUDIO_BIT_WIDTH(16),
        .VENDOR_NAME({"NextTang"}),
        .PRODUCT_DESCRIPTION({"Nano20K bringup", 8'd0})
    ) transmitter (
        .clk_pixel_x5(serial_clock),
        .clk_pixel(pixel_clock),
        .audio_ce(1'b0),
        .reset(pixel_reset),
        .alt_mode(1'b0),
        .rgb(rgb),
        .audio_sample_word('{16'sd0, 16'sd0}),
        .tmds(serial_data),
        .tmds_clock(serial_tmds_clock),
        .cx(cx), .cy(cy),
        .frame_width(), .frame_height(), .screen_width(), .screen_height()
    );

    ELVDS_OBUF clock_output (.I(serial_tmds_clock), .O(tmds_clk_p), .OB(tmds_clk_n));
    ELVDS_OBUF data_output_0 (.I(serial_data[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF data_output_1 (.I(serial_data[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF data_output_2 (.I(serial_data[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));

    // picture: 720x576 active area
    reg [9:0] box_x = 10'd0, box_y = 10'd0;
    reg       box_dx = 1'b1, box_dy = 1'b1;
    wire      frame_start = cx == 12'd0 && cy == 10'd0;
    always @(posedge pixel_clock) if (frame_start) begin
        box_x <= box_dx ? box_x + 10'd1 : box_x - 10'd1;
        box_y <= box_dy ? box_y + 10'd1 : box_y - 10'd1;
        if (box_x == 10'd1) box_dx <= 1'b1; else if (box_x == 10'd655) box_dx <= 1'b0;
        if (box_y == 10'd1) box_dy <= 1'b1; else if (box_y == 10'd511) box_dy <= 1'b0;
    end

    reg [1:0] b0_sync = 2'b00, b1_sync = 2'b00;
    always @(posedge pixel_clock) begin
        b0_sync <= {b0_sync[0], button[0]};
        b1_sync <= {b1_sync[0], button[1]};
    end

    // SDRAM results into the pixel domain (slow-changing; a torn sample is
    // only a display glitch for one frame)
    reg [15:0] px_passes = 16'd0, px_passes_s = 16'd0;
    reg [23:0] px_ea = 24'd0, px_ea_s = 24'd0, px_eb = 24'd0, px_eb_s = 24'd0;
    reg [1:0]  px_init = 2'b00;
    always @(posedge pixel_clock) begin
        px_passes_s <= sd_passes; px_passes <= px_passes_s;
        px_ea_s <= sd_errors_a;  px_ea <= px_ea_s;
        px_eb_s <= sd_errors_b;  px_eb <= px_eb_s;
        px_init <= {px_init[0], sd_init_done};
    end
    // panel, rows 400..559: left half capture A, right half capture B.
    // grey = no complete pass yet, green = passes and no errors, red = errors.
    // Row 400..439: 16 squares, pass count in binary (bit 15 left), white = 1.
    // Rows 450..489 (A) and 500..539 (B): 24 squares, error count in binary.
    wire in_panel  = cy >= 10'd400 && cy < 10'd560 && cx >= 12'd40 && cx < 12'd680;
    wire panel_b   = cx >= 12'd360;
    wire [23:0] panel_err = panel_b ? px_eb : px_ea;
    wire [23:0] panel_colour = !px_init[1] ? 24'h202020
                             : px_passes == 16'd0 ? 24'h606060
                             : panel_err == 24'd0 ? 24'h00A000 : 24'hC00000;
    wire [11:0] sq_x = cx - 12'd40;          // 0..639
    wire [5:0]  sq16 = sq_x / 12'd40;          // 0..15
    wire [5:0]  sq24 = (sq_x * 12'd3) / 12'd80; // 0..23 (26.7-pixel squares)
    wire in_pass_row = cy >= 10'd405 && cy < 10'd435;
    wire in_ea_row   = cy >= 10'd455 && cy < 10'd485;
    wire in_eb_row   = cy >= 10'd505 && cy < 10'd535;
    wire pass_one    = px_passes[5'd15 - sq16[4:0]];
    wire ea_one      = px_ea[5'd23 - sq24[4:0]];
    wire eb_one      = px_eb[5'd23 - sq24[4:0]];

    wire in_box    = cx >= {2'b00, box_x} && cx < {2'b00, box_x} + 12'd64 && cy >= box_y && cy < box_y + 10'd64;
    wire in_corner = cx >= 12'd8 && cx < 12'd40 && cy >= 10'd8 && cy < 10'd40;
    wire on_border = cx == 12'd1 || cx == 12'd718 || cy == 10'd1 || cy == 10'd574;
    wire [2:0] bar = cx < 12'd90 ? 3'd7 : cx < 12'd180 ? 3'd6 : cx < 12'd270 ? 3'd5 : cx < 12'd360 ? 3'd4 :
                     cx < 12'd450 ? 3'd3 : cx < 12'd540 ? 3'd2 : cx < 12'd630 ? 3'd1 : 3'd0;
    always @(*) begin
        if (cx >= 12'd720 || cy >= 10'd576) rgb = 24'h000000;
        else if (in_corner) rgb = {{8{b0_sync[1]}}, {8{b1_sync[1]}}, 8'h40};
        else if (in_panel && in_pass_row && sq_x % 12'd40 > 12'd3) rgb = pass_one ? 24'hFFFFFF : 24'h000000;
        else if (in_panel && in_ea_row) rgb = ea_one ? 24'hFF4040 : 24'h102010;
        else if (in_panel && in_eb_row) rgb = eb_one ? 24'hFF4040 : 24'h102010;
        else if (in_panel) rgb = panel_colour;
        else if (on_border) rgb = 24'hFFFFFF;
        else if (in_box) rgb = 24'hFFFFFF;
        else rgb = {{8{bar[1]}}, {8{bar[2]}}, {8{bar[0]}}};  // R, G, B from bar code (EBU order)
    end

    // 1 Hz blink from the pixel clock
    reg [24:0] blink = 25'd0;
    reg blink_led = 1'b0;
    always @(posedge pixel_clock)
        if (blink == 25'd13_499_999) begin blink <= 25'd0; blink_led <= !blink_led; end
        else blink <= blink + 25'd1;

    wire a_ok = px_passes != 16'd0 && px_ea == 24'd0;
    wire b_ok = px_passes != 16'd0 && px_eb == 24'd0;
    assign led = ~{b_ok, a_ok, px_init[1], sdram_lock, blink_led, pll_lock};
endmodule

`default_nettype wire
