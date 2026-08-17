// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_console138k_ddr3_logo (
    input  wire        sys_clk,
    output wire        status_led,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
    output wire [14:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs,
    output wire        ddr_ras,
    output wire        ddr_cas,
    output wire        ddr_we,
    output wire        ddr_ck,
    output wire        ddr_ck_n,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [3:0]  ddr_dm,
    inout  wire [31:0] ddr_dq,
    inout  wire [3:0]  ddr_dqs,
    inout  wire [3:0]  ddr_dqs_n
);
    wire video_serial_clock;
    wire pixel_clock;
    wire video_pll_locked;
    reg [3:0] pixel_reset_shift = 0;
    wire pixel_reset = !pixel_reset_shift[3];

    wire memory_clock;
    wire memory_reference_clock;
    wire memory_pll_locked;
    wire memory_clock_enable;
    wire controller_clock;
    wire controller_clock_enable;
    reg [7:0] controller_reset_shift = 0;
    wire controller_reset_n = controller_reset_shift[7];
    wire calibration_complete;

    wire controller_command_ready;
    wire [2:0] controller_command;
    wire controller_command_enable;
    wire [28:0] controller_address;
    wire controller_write_data_ready;
    wire [255:0] controller_write_data;
    wire controller_write_data_enable;
    wire controller_write_data_end;
    wire [31:0] controller_write_data_mask;
    wire [255:0] controller_read_data;
    wire controller_read_data_valid;
    wire controller_read_data_end;
    wire controller_burst;
    wire self_refresh_acknowledge;
    wire refresh_acknowledge;
    wire ddr_reset;

    wire engine_completion_toggle;
    wire engine_completion_bank;
    wire engine_logo_ready;
    wire engine_buffer_write_enable;
    wire engine_buffer_write_bank;
    wire [8:0] engine_buffer_write_address;
    wire [255:0] engine_buffer_write_data;
    wire [2:0] engine_status;

    wire pixel_reload_request_toggle;
    wire pixel_reload_request_bank;
    reg reload_request_toggle_metastability = 0;
    reg reload_request_toggle_controller = 0;
    reg reload_request_bank_metastability = 0;
    reg reload_request_bank_controller = 0;

    reg completion_toggle_metastability = 0;
    reg completion_toggle_pixel = 0;
    reg completion_bank_metastability = 0;
    reg completion_bank_pixel = 0;
    reg [2:0] status_metastability = 0;
    reg [2:0] status_pixel = 0;

    wire framebuffer_read_bank;
    wire [13:0] framebuffer_read_address;
    wire [7:0] framebuffer_read_data;
    wire logo_available_pixel;
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;
    wire hsync;
    wire vsync;
    wire data_enable;
    wire [10:0] horizontal_position;
    wire [9:0] vertical_position;
    wire display_logo = logo_available_pixel && status_pixel < 3'd4;
    wire status_border = horizontal_position < 32 ||
                         horizontal_position >= 1248 ||
                         vertical_position < 32 ||
                         vertical_position >= 688;
    wire [23:0] status_colour;
    wire [23:0] video_colour = display_logo ? {red, green, blue}
        : status_border ? 24'hffffff : status_colour;
    wire [9:0] red_symbol;
    wire [9:0] green_symbol;
    wire [9:0] blue_symbol;
    wire [2:0] serial_data;

    nexttang_console138k_pll video_pll (
        .clock_in(sys_clk),
        .serial_clock(video_serial_clock),
        .locked(video_pll_locked)
    );

    CLKDIV #(.DIV_MODE(5)) pixel_clock_divider (
        .HCLKIN(video_serial_clock),
        .RESETN(video_pll_locked),
        .CALIB(1'b0),
        .CLKOUT(pixel_clock)
    );

    always @(posedge pixel_clock or negedge video_pll_locked) begin
        if (!video_pll_locked)
            pixel_reset_shift <= 0;
        else
            pixel_reset_shift <= {pixel_reset_shift[2:0], 1'b1};
    end

    nexttang_console138k_ddr3_pll memory_pll (
        .clock_in(sys_clk),
        .clock_enable(memory_clock_enable),
        .memory_clock(memory_clock),
        .reference_clock(memory_reference_clock),
        .locked(memory_pll_locked)
    );

    always @(posedge sys_clk or negedge memory_pll_locked) begin
        if (!memory_pll_locked)
            controller_reset_shift <= 0;
        else
            controller_reset_shift <= {
                controller_reset_shift[6:0], 1'b1
            };
    end

    assign memory_clock_enable =
        !controller_reset_n || controller_clock_enable;

    always @(posedge controller_clock or negedge controller_reset_n) begin
        if (!controller_reset_n) begin
            reload_request_toggle_metastability <= 0;
            reload_request_toggle_controller <= 0;
            reload_request_bank_metastability <= 0;
            reload_request_bank_controller <= 0;
        end else begin
            reload_request_toggle_metastability <=
                pixel_reload_request_toggle;
            reload_request_toggle_controller <=
                reload_request_toggle_metastability;
            reload_request_bank_metastability <= pixel_reload_request_bank;
            reload_request_bank_controller <=
                reload_request_bank_metastability;
        end
    end

    always @(posedge pixel_clock) begin
        if (pixel_reset) begin
            completion_toggle_metastability <= 0;
            completion_toggle_pixel <= 0;
            completion_bank_metastability <= 0;
            completion_bank_pixel <= 0;
            status_metastability <= 0;
            status_pixel <= 0;
        end else begin
            completion_toggle_metastability <= engine_completion_toggle;
            completion_toggle_pixel <= completion_toggle_metastability;
            completion_bank_metastability <= engine_completion_bank;
            completion_bank_pixel <= completion_bank_metastability;
            status_metastability <= controller_reset_n
                ? engine_status : 3'd0;
            status_pixel <= status_metastability;
        end
    end

    nexttang_ddr3_logo_engine #(
        .LOGO_FILE("nexttang_logo_128x128_rgb332.mem")
    ) logo_engine (
        .clock(controller_clock),
        .reset(!controller_reset_n),
        .calibration_complete(calibration_complete),
        .reload_request_toggle(reload_request_toggle_controller),
        .reload_request_bank(reload_request_bank_controller),
        .completion_toggle(engine_completion_toggle),
        .completion_bank(engine_completion_bank),
        .logo_ready(engine_logo_ready),
        .buffer_write_enable(engine_buffer_write_enable),
        .buffer_write_bank(engine_buffer_write_bank),
        .buffer_write_address(engine_buffer_write_address),
        .buffer_write_data(engine_buffer_write_data),
        .controller_command_ready(controller_command_ready),
        .controller_command(controller_command),
        .controller_command_enable(controller_command_enable),
        .controller_address(controller_address),
        .controller_write_data_ready(controller_write_data_ready),
        .controller_write_data(controller_write_data),
        .controller_write_data_enable(controller_write_data_enable),
        .controller_write_data_end(controller_write_data_end),
        .controller_write_data_mask(controller_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(controller_read_data_valid),
        .controller_burst(controller_burst),
        .status(engine_status)
    );

    nexttang_logo_framebuffer logo_framebuffer (
        .write_clock(controller_clock),
        .write_enable(engine_buffer_write_enable),
        .write_bank(engine_buffer_write_bank),
        .write_address(engine_buffer_write_address),
        .write_data(engine_buffer_write_data),
        .read_clock(pixel_clock),
        .read_bank(framebuffer_read_bank),
        .read_address(framebuffer_read_address),
        .read_data(framebuffer_read_data)
    );

    nexttang_ddr_logo_video logo_video (
        .pixel_clock(pixel_clock),
        .reset(pixel_reset),
        .completion_toggle(completion_toggle_pixel),
        .completion_bank(completion_bank_pixel),
        .reload_request_toggle(pixel_reload_request_toggle),
        .reload_request_bank(pixel_reload_request_bank),
        .framebuffer_read_bank(framebuffer_read_bank),
        .framebuffer_read_address(framebuffer_read_address),
        .framebuffer_read_data(framebuffer_read_data),
        .logo_available(logo_available_pixel),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    DDR3_Memory_Interface_Top ddr3 (
        .clk(sys_clk),
        .pll_stop(controller_clock_enable),
        .memory_clk(memory_clock),
        .pll_lock(memory_pll_locked),
        .rst_n(controller_reset_n),
        .clk_out(controller_clock),
        .ddr_rst(ddr_reset),
        .init_calib_complete(calibration_complete),
        .cmd_ready(controller_command_ready),
        .cmd(controller_command),
        .cmd_en(controller_command_enable),
        .addr(controller_address),
        .wr_data_rdy(controller_write_data_ready),
        .wr_data(controller_write_data),
        .wr_data_en(controller_write_data_enable),
        .wr_data_end(controller_write_data_end),
        .wr_data_mask(controller_write_data_mask),
        .rd_data(controller_read_data),
        .rd_data_valid(controller_read_data_valid),
        .rd_data_end(controller_read_data_end),
        .sr_req(1'b0), .ref_req(1'b0),
        .sr_ack(self_refresh_acknowledge),
        .ref_ack(refresh_acknowledge),
        .burst(controller_burst),
        .O_ddr_addr(ddr_addr), .O_ddr_ba(ddr_bank),
        .O_ddr_cs_n(ddr_cs), .O_ddr_ras_n(ddr_ras),
        .O_ddr_cas_n(ddr_cas), .O_ddr_we_n(ddr_we),
        .O_ddr_clk(ddr_ck), .O_ddr_clk_n(ddr_ck_n),
        .O_ddr_cke(ddr_cke), .O_ddr_odt(ddr_odt),
        .O_ddr_reset_n(ddr_reset_n), .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq), .IO_ddr_dqs(ddr_dqs),
        .IO_ddr_dqs_n(ddr_dqs_n)
    );

    nexttang_status_colour colour_lookup (
        .status(status_pixel), .colour(status_colour)
    );

    nexttang_tmds_encoder blue_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(video_colour[7:0]),
        .control_zero(hsync), .control_one(vsync),
        .data_enable(data_enable), .symbol(blue_symbol)
    );
    nexttang_tmds_encoder green_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(video_colour[15:8]),
        .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(green_symbol)
    );
    nexttang_tmds_encoder red_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(video_colour[23:16]),
        .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(red_symbol)
    );

    OSER10 blue_serializer (
        .D0(blue_symbol[0]), .D1(blue_symbol[1]),
        .D2(blue_symbol[2]), .D3(blue_symbol[3]),
        .D4(blue_symbol[4]), .D5(blue_symbol[5]),
        .D6(blue_symbol[6]), .D7(blue_symbol[7]),
        .D8(blue_symbol[8]), .D9(blue_symbol[9]),
        .PCLK(pixel_clock), .FCLK(video_serial_clock),
        .RESET(1'b0), .Q(serial_data[0])
    );
    OSER10 green_serializer (
        .D0(green_symbol[0]), .D1(green_symbol[1]),
        .D2(green_symbol[2]), .D3(green_symbol[3]),
        .D4(green_symbol[4]), .D5(green_symbol[5]),
        .D6(green_symbol[6]), .D7(green_symbol[7]),
        .D8(green_symbol[8]), .D9(green_symbol[9]),
        .PCLK(pixel_clock), .FCLK(video_serial_clock),
        .RESET(1'b0), .Q(serial_data[1])
    );
    OSER10 red_serializer (
        .D0(red_symbol[0]), .D1(red_symbol[1]),
        .D2(red_symbol[2]), .D3(red_symbol[3]),
        .D4(red_symbol[4]), .D5(red_symbol[5]),
        .D6(red_symbol[6]), .D7(red_symbol[7]),
        .D8(red_symbol[8]), .D9(red_symbol[9]),
        .PCLK(pixel_clock), .FCLK(video_serial_clock),
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

    assign status_led = engine_logo_ready && engine_status < 3'd4
        ? 1'b0 : 1'b1;
endmodule

`default_nettype wire
