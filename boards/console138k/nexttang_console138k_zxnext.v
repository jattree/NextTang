// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// First ZX Spectrum Next image for the Tang Console 138K.
//
// The pinned MiSTer ZXNext core runs on the machine clock tree with the
// project's diagnostic boot ROM in place of the excluded upstream one. Main
// memory is a 64 KiB block RAM standing in for the 2 MB SRAM space; addresses
// alias above it, which is enough for the diagnostic's 16 KiB test window at
// 0x8000 and nothing more. Layer 2's video port reads zero. The core's own
// HDMI window is captured at 7 MHz and scaled into the established 720p
// output, and the status UART reports how far the machine got without HDMI.

`default_nettype none

module nexttang_console138k_zxnext (
    input  wire       sys_clk,
    output wire       debug_uart_tx,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire       tmds_psv
);
    // ----------------------------------------------------------------- clocks
    wire serial_clock;
    wire pixel_clock;
    wire video_pll_locked;

    nexttang_console138k_pll video_pll (
        .clock_in(sys_clk),
        .serial_clock(serial_clock),
        .pixel_clock(pixel_clock),
        .locked(video_pll_locked)
    );

    wire clock_28;
    wire clock_28_n;
    wire clock_14;
    wire clock_7;
    wire clock_3m5;
    wire cpu_clock;
    wire psg_enable;
    wire machine_reset;
    wire machine_locked;
    wire [1:0] cpu_speed;
    wire cpu_contend;
    wire cpu_clock_lsb;

    nexttang_console138k_machine_clock_tree clock_tree (
        .clock_27(sys_clk),
        .force_reset(1'b0),
        .memory_calibrated(1'b1),
        .memory_fault(1'b0),
        .cpu_clock_lsb(cpu_clock_lsb),
        .cpu_contend(cpu_contend),
        .cpu_speed(cpu_speed),
        .clock_28(clock_28),
        .clock_28_n(clock_28_n),
        .clock_14(clock_14),
        .clock_7(clock_7),
        .clock_3m5(clock_3m5),
        .cpu_clock(cpu_clock),
        .psg_enable(psg_enable),
        .machine_reset(machine_reset),
        .clock_locked(machine_locked)
    );

    // ------------------------------------------------------------------- core
    wire [20:0] ram_a_address;
    wire        ram_a_request;
    wire        ram_a_read_n;
    wire [7:0]  ram_a_write_data;
    wire [7:0]  ram_a_read_data;

    wire [8:0]  core_rgb;
    wire        core_vsync_n;
    wire        core_hdmi_pixel;
    wire        core_hdmi_lock;
    wire        core_m1_n;
    wire [15:0] core_bus_address;

    zxnext #(
        .g_video_def(3'b000),
        .g_version(8'h32),
        .g_sub_version(8'h00),
        .g_video_inc(2'b10)
    ) core (
        .g_machine_id(8'h0A),
        .g_board_issue(4'h2),

        .i_CLK_28(clock_28),
        .i_CLK_28_n(clock_28_n),
        .i_CLK_14(clock_14),
        .i_CLK_7(clock_7),
        .i_CLK_CPU(cpu_clock),
        .i_CLK_PSG_EN(psg_enable),
        .o_CPU_SPEED(cpu_speed),
        .o_CPU_CONTEND(cpu_contend),
        .o_CPU_CLK_LSB(cpu_clock_lsb),

        // Power-on reset doubles as the boot flag, as MiSTer's HW_RESET does.
        .i_RESET(machine_reset),
        .i_BOOT(machine_reset),
        .o_RESET_SOFT(),
        .o_RESET_HARD(),
        .o_RESET_PERIPHERAL(),
        .o_FLASH_BOOT(),
        .o_CORE_ID(),

        .i_SPKEY_FUNCTION(10'b0),
        .i_SPKEY_BUTTONS(2'b0),

        // No keyboard yet: every column reads released.
        .o_KBD_CANCEL(),
        .o_KBD_ROW(),
        .i_KBD_COL(5'b11111),
        .i_KBD_EXTENDED_KEYS(16'hffff),
        .o_KEYMAP_ADDR(),
        .o_KEYMAP_DATA(),
        .o_KEYMAP_WE(),
        .o_JOYMAP_WE(),
        .i_JOY_LEFT(12'b0),
        .i_JOY_RIGHT(12'b0),
        .o_JOY_IO_MODE_EN(),
        .o_JOY_IO_MODE_PIN_7(),
        .o_JOY_LEFT_TYPE(),
        .o_JOY_RIGHT_TYPE(),
        .i_MOUSE_X(8'b0),
        .i_MOUSE_Y(8'b0),
        .i_MOUSE_BUTTON(3'b0),
        .i_MOUSE_WHEEL(4'b0),
        .o_PS2_MODE(),
        .o_MOUSE_CONTROL(),

        .i_I2C_SCL_n(1'b1),
        .i_I2C_SDA_n(1'b1),
        .o_I2C_SCL_n(),
        .o_I2C_SDA_n(),

        // No SD card yet: MISO idles high, as an empty socket does.
        .o_SPI_SS_FLASH_n(),
        .o_SPI_SS_SD1_n(),
        .o_SPI_SS_SD0_n(),
        .o_SPI_SCK(),
        .o_SPI_MOSI(),
        .i_SPI_SD_MISO(1'b1),
        .i_SPI_FLASH_MISO(1'b1),

        .i_UART0_RX(1'b1),
        .o_UART0_TX(),
        .i_UART0_CTS_n(1'b0),
        .o_UART0_RTR_n(),

        .o_RGB(core_rgb),
        .o_RGB_CS_n(),
        .o_RGB_VS_n(core_vsync_n),
        .o_RGB_HS_n(),
        .o_RGB_VB_n(),
        .o_RGB_HB_n(),
        .o_VIDEO_50_60(),
        .o_VIDEO_SCANLINES(),
        .o_VIDEO_SCANDOUBLE(),
        .o_VIDEO_MODE(),
        .o_MACHINE_TIMING(),
        .o_HDMI_RESET(),
        .o_HDMI_PIXEL(core_hdmi_pixel),
        .o_HDMI_LOCK(core_hdmi_lock),
        .center(1'b1),

        .o_AUDIO_HDMI_AUDIO_EN(),
        .o_AUDIO_SPEAKER_EN(),
        .o_AUDIO_SPEAKER_EXCL(),
        .i_AUDIO_EAR(1'b0),
        .o_AUDIO_MIC(),
        .o_AUDIO_EAR(),
        .o_AUDIO_L(),
        .o_AUDIO_R(),

        .o_RAM_A_ADDR(ram_a_address),
        .o_RAM_A_REQ(ram_a_request),
        .o_RAM_A_REQ2(),
        .i_RAM_A_REQ_ALLOW(1'b0),
        .o_RAM_A_RD_n(ram_a_read_n),
        .i_RAM_A_DI(ram_a_read_data),
        .o_RAM_A_DO(ram_a_write_data),
        .o_RAM_A_CYCLE(),
        .o_RAM_A_RFSH(),
        // Active high. The port defaults to '1', which would hold the CPU.
        .i_CPU_WAIT(1'b0),

        .o_RAM_B_ADDR(),
        .o_RAM_B_REQ_T(),
        .i_RAM_B_DI(8'h00),

        .o_BUS_ADDR(core_bus_address),
        .i_BUS_DI(8'hff),
        .o_BUS_DO(),
        .o_BUS_MREQ_n(),
        .o_BUS_IORQ_n(),
        .o_BUS_RD_n(),
        .o_BUS_WR_n(),
        .o_BUS_M1_n(core_m1_n),
        .i_BUS_WAIT_n(1'b1),
        .i_BUS_NMI_n(1'b1),
        .i_BUS_INT_n(1'b1),
        .o_BUS_INT_n(),
        .i_BUS_BUSREQ_n(1'b1),
        .o_BUS_BUSAK_n(),
        .o_BUS_HALT_n(),
        .o_BUS_RFSH_n(),
        .o_BUS_IEO(),
        .i_BUS_ROMCS_n(1'b1),
        .i_BUS_IORQULA_n(1'b1),
        .o_BUS_EN(),
        .o_BUS_CLKEN(),
        .o_BUS_NMI_DEBOUNCE_DISABLE(),

        .i_ESP_GPIO_20(3'b111),
        .o_ESP_GPIO_0(),
        .o_ESP_GPIO_0_EN(),
        .i_GPIO(28'b0),
        .o_GPIO(),
        .o_GPIO_EN()
    );

    // ---------------------------------------------------------- main memory
    // The core raises o_RAM_A_REQ for exactly one rising 28 MHz edge per
    // memory cycle, so a write lands once. Reads return one 28 MHz cycle after
    // the address, far inside the CPU's own read window at 3.5 MHz.
    wire ram_a_write = ram_a_request && ram_a_read_n;

    nexttang_block_ram #(
        .ADDRESS_BITS(16),
        .DATA_BITS(8)
    ) main_memory (
        .clock(clock_28),
        .write_enable(ram_a_write),
        .write_address(ram_a_address[15:0]),
        .write_data(ram_a_write_data),
        .read_data(ram_a_read_data),
        .port_b_clock(clock_28),
        .port_b_address(16'b0),
        .port_b_data()
    );

    // ------------------------------------------------------------------ video
    // The core's RGB and HDMI pixel window leave its 14 MHz pipeline together.
    // Standard-resolution pixels last two 14 MHz cycles, so sampling at 7 MHz
    // takes one whole pixel per sample.
    reg [8:0] sampled_rgb = 9'b0;
    reg       sampled_pixel = 1'b0;

    always @(posedge clock_7) begin
        sampled_rgb <= core_rgb;
        sampled_pixel <= core_hdmi_pixel;
    end

    wire capture_frame_start;
    wire capture_pixel_valid;
    wire [8:0] capture_x;
    wire [8:0] capture_y;
    wire [8:0] capture_pixel;
    wire capture_protocol_error;

    nexttang_ula_capture #(
        .PIXEL_BITS(9)
    ) capture (
        .clock(clock_7),
        .reset(!machine_locked),
        .frame_sync(core_hdmi_lock),
        .pixel_valid(sampled_pixel),
        .pixel(sampled_rgb),
        .capture_frame_start(capture_frame_start),
        .capture_pixel_valid(capture_pixel_valid),
        .capture_x(capture_x),
        .capture_y(capture_y),
        .capture_pixel(capture_pixel),
        .protocol_error(capture_protocol_error)
    );

    reg [3:0] pixel_reset_shift = 4'b0;
    wire pixel_reset = !pixel_reset_shift[3];

    always @(posedge pixel_clock or negedge video_pll_locked) begin
        if (!video_pll_locked)
            pixel_reset_shift <= 4'b0;
        else
            pixel_reset_shift <= {pixel_reset_shift[2:0], 1'b1};
    end

    wire timing_hsync;
    wire timing_vsync;
    wire timing_data_enable;
    wire [10:0] horizontal_position;
    wire [9:0] vertical_position;

    nexttang_video_timing timing (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .hsync(timing_hsync),
        .vsync(timing_vsync),
        .data_enable(timing_data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    wire hsync;
    wire vsync;
    wire data_enable;
    wire [8:0] scaled_pixel;
    wire scaled_frame_valid;
    wire scaled_overrun;
    wire output_frame_start = horizontal_position == 0 && vertical_position == 0;

    nexttang_framebuffer_scaler #(
        .PIXEL_BITS(9)
    ) scaler (
        .source_clock(clock_7),
        .source_reset(!machine_locked),
        .source_frame_start(capture_frame_start),
        .source_pixel_valid(capture_pixel_valid),
        .source_x(capture_x),
        .source_y(capture_y),
        .source_pixel(capture_pixel),
        .source_overrun(scaled_overrun),
        .output_clock(pixel_clock),
        .output_reset(pixel_reset),
        .output_frame_start(output_frame_start),
        .output_hsync(timing_hsync),
        .output_vsync(timing_vsync),
        .output_data_enable(timing_data_enable),
        .output_x(horizontal_position),
        .output_y(vertical_position),
        .scaled_hsync(hsync),
        .scaled_vsync(vsync),
        .scaled_data_enable(data_enable),
        .scaled_pixel(scaled_pixel),
        .output_frame_valid(scaled_frame_valid)
    );

    // The 152-block frame store's read multiplexer and the TMDS encoders do
    // not fit one 75 MHz cycle together, so the pixel and its timing are
    // registered once between them.
    reg [8:0] output_pixel = 9'b0;
    reg output_hsync = 1'b0;
    reg output_vsync = 1'b0;
    reg output_data_enable = 1'b0;

    always @(posedge pixel_clock) begin
        output_pixel <= scaled_pixel;
        output_hsync <= hsync;
        output_vsync <= vsync;
        output_data_enable <= data_enable;
    end

    // RGB333 to 8 bits per channel by repeating each field's bits.
    wire [7:0] red   = {output_pixel[8:6], output_pixel[8:6], output_pixel[8:7]};
    wire [7:0] green = {output_pixel[5:3], output_pixel[5:3], output_pixel[5:4]};
    wire [7:0] blue  = {output_pixel[2:0], output_pixel[2:0], output_pixel[2:1]};

    wire [9:0] red_symbol;
    wire [9:0] green_symbol;
    wire [9:0] blue_symbol;
    wire [2:0] serial_data;

    nexttang_tmds_encoder blue_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(blue), .control_zero(output_hsync), .control_one(output_vsync),
        .data_enable(output_data_enable), .symbol(blue_symbol)
    );
    nexttang_tmds_encoder green_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(green), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(output_data_enable), .symbol(green_symbol)
    );
    nexttang_tmds_encoder red_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(red), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(output_data_enable), .symbol(red_symbol)
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
        .I(pixel_clock), .O(tmds_clk_p), .OB(tmds_clk_n));
    ELVDS_OBUF data_output_zero (
        .I(serial_data[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF data_output_one (
        .I(serial_data[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF data_output_two (
        .I(serial_data[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));

    assign tmds_psv = 1'b1;

    // --------------------------------------------------------------- reporting
    // Opcode fetches and main-memory writes are counted in the 28 MHz domain.
    // The diagnostic's test window at 0x8000 lands in SRAM page 0x24, which
    // the stand-in memory sees at 0x8000.
    reg m1_previous = 1'b1;
    reg opcode_seen = 1'b0;
    reg [15:0] opcode_count = 16'b0;
    reg [15:0] opcode_address = 16'b0;
    reg test_window_write_seen = 1'b0;

    always @(posedge clock_28) begin
        if (machine_reset) begin
            m1_previous <= 1'b1;
            opcode_seen <= 1'b0;
            opcode_count <= 16'b0;
            opcode_address <= 16'b0;
            test_window_write_seen <= 1'b0;
        end else begin
            m1_previous <= core_m1_n;
            if (m1_previous && !core_m1_n) begin
                opcode_seen <= 1'b1;
                opcode_count <= opcode_count + 1'b1;
                opcode_address <= core_bus_address;
            end
            if (ram_a_write && ram_a_address[15:14] == 2'b10)
                test_window_write_seen <= 1'b1;
        end
    end

    // The first captured pixel of each frame is top-left border, so it reports
    // the border colour the diagnostic set: green on pass, red on failure.
    reg [8:0] border_rgb = 9'b0;
    reg frame_seen = 1'b0;
    reg lit_pixel_seen = 1'b0;

    always @(posedge clock_7) begin
        if (!machine_locked) begin
            border_rgb <= 9'b0;
            frame_seen <= 1'b0;
            lit_pixel_seen <= 1'b0;
        end else begin
            if (capture_frame_start) begin
                border_rgb <= capture_pixel;
                frame_seen <= 1'b1;
            end
            if (capture_pixel_valid && capture_pixel != 9'b0)
                lit_pixel_seen <= 1'b1;
        end
    end

    // V video PLL, M machine out of reset, R a non-black pixel captured,
    // C opcode fetched, P test window written, Y frame captured.
    wire [5:0] status_flags = {
        frame_seen, test_window_write_seen, opcode_seen,
        lit_pixel_seen, !machine_reset, video_pll_locked
    };
    // Last opcode address, border colour, CPU speed, capture and scaler faults.
    wire [31:0] status_value = {
        opcode_address, border_rgb, cpu_speed, capture_protocol_error,
        scaled_overrun, 3'b0
    };

    nexttang_debug_status_uart #(
        .CLOCK_HZ(7000000),
        .GAP_CLOCKS(1750000)
    ) status_uart (
        .clock(clock_7),
        .reset(!machine_locked),
        .flags(status_flags),
        .value(status_value),
        .transmit(debug_uart_tx)
    );
endmodule

`default_nettype wire
