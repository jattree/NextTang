// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// ZX Spectrum Next images for the Tang Console 138K.
//
// The pinned MiSTer ZXNext core runs on the machine clock tree with the
// project's diagnostic boot ROM in place of the excluded upstream one. Layer
// 2's video port reads zero. The core's own HDMI window is captured at 7 MHz
// and scaled into the established 720p output, and the status UART reports how
// far the machine got without HDMI.
//
// Main memory depends on the profile. By default it is a 64 KiB block RAM
// standing in for the 2 MB SRAM space; addresses alias above it, which is
// enough for the diagnostic's 16 KiB test window at 0x8000 and nothing more.
// With NEXTTANG_ZXNEXT_DDR3 defined, the whole 2 MB space lives in DDR3
// behind the hardware-verified CPU memory service, and the machine is held in
// reset until the controller calibrates.
//
// With NEXTTANG_ZXNEXT_IO defined, the core's own SPI drives the SD socket and
// the two USB-A sockets carry the direct USB hosts. A keyboard is scanned into
// the core's keyboard port and a gamepad becomes the left joystick.

`default_nettype none

`ifndef NEXTTANG_ZXNEXT_TOP
`define NEXTTANG_ZXNEXT_TOP nexttang_console138k_zxnext
`endif

module `NEXTTANG_ZXNEXT_TOP (
    input  wire       sys_clk,
    output wire       debug_uart_tx,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire       tmds_psv
`ifdef NEXTTANG_ZXNEXT_DDR3
    ,
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
`endif
`ifdef NEXTTANG_ZXNEXT_IO
    ,
    output wire        sd_clk,
    output wire        sd_mosi,
    output wire        sd_cs,
    input  wire        sd_miso,
    inout  wire        usb1_dp,
    inout  wire        usb1_dn,
    inout  wire        usb2_dp,
    inout  wire        usb2_dn
`endif
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
    wire cpu_rising_enable;
    wire cpu_falling_enable;
    wire cpu_enables_locked;
    wire psg_enable;
    wire machine_reset;
    wire machine_locked;
    wire [1:0] cpu_speed;
    wire cpu_contend;
    wire cpu_clock_lsb;

`ifdef NEXTTANG_ZXNEXT_DDR3
    // ------------------------------------------------------------ DDR3 clocks
    wire memory_clock;
    wire memory_reference_clock;
    wire memory_pll_locked;
    wire memory_clock_enable;
    wire controller_clock;
    wire controller_clock_enable;
    reg [7:0] controller_reset_shift = 8'b0;
    wire controller_reset_n = controller_reset_shift[7];
    wire calibration_complete;
    wire ddr_reset;

    nexttang_console138k_ddr3_pll memory_pll (
        .clock_in(sys_clk),
        .clock_enable(memory_clock_enable),
        .memory_clock(memory_clock),
        .reference_clock(memory_reference_clock),
        .locked(memory_pll_locked)
    );

    always @(posedge sys_clk or negedge memory_pll_locked) begin
        if (!memory_pll_locked)
            controller_reset_shift <= 8'b0;
        else
            controller_reset_shift <= {controller_reset_shift[6:0], 1'b1};
    end

    assign memory_clock_enable = !controller_reset_n || controller_clock_enable;

    wire fault_timeout;
    wire fault_overrun;
    wire fault_calibration_lost;
    wire memory_fault = fault_timeout || fault_overrun || fault_calibration_lost;
`else
    wire calibration_complete = 1'b1;
    wire memory_fault = 1'b0;
`endif

    nexttang_console138k_machine_clock_tree clock_tree (
        .clock_27(sys_clk),
        .force_reset(1'b0),
        .memory_calibrated(calibration_complete),
        .memory_fault(memory_fault),
        .clock_28(clock_28),
        .clock_28_n(clock_28_n),
        .clock_14(clock_14),
        .clock_7(clock_7),
        .psg_enable(psg_enable),
        .machine_reset(machine_reset),
        .clock_locked(machine_locked)
    );

    // The CPU runs on clock_28. These enables mark where its rising and
    // falling edges would have been, at the speed the core asks for and with
    // 3.5 MHz contention, by MiSTer's rules.
    nexttang_zxnext_cpu_enables cpu_enables (
        .i_CLK_28(clock_28),
        .i_CLK_7(clock_7),
        .i_CPU_SPEED(cpu_speed),
        .i_CPU_CONTEND(cpu_contend),
        .i_CPU_CLK_LSB(cpu_clock_lsb),
        .o_CEN_R(cpu_rising_enable),
        .o_CEN_F(cpu_falling_enable),
        .o_LOCKED(cpu_enables_locked)
    );

    // ------------------------------------------------------------------- core
    wire [20:0] ram_a_address;
    wire        ram_a_request;
    wire        ram_a_cycle_request;
    wire        cpu_wait;
    wire [7:0]  keyboard_rows;
    wire [4:0]  keyboard_columns;
    wire [11:0] left_joystick;
    wire        spi_clock;
    wire        spi_mosi;
    wire        spi_sd0_select_n;
    wire        spi_sd_miso;
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
        .i_CLK_CPU(clock_28),
        .i_CPU_CEN_R(cpu_rising_enable),
        .i_CPU_CEN_F(cpu_falling_enable),
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

        .o_KBD_CANCEL(),
        .o_KBD_ROW(keyboard_rows),
        .i_KBD_COL(keyboard_columns),
        .i_KBD_EXTENDED_KEYS(16'hffff),
        .o_KEYMAP_ADDR(),
        .o_KEYMAP_DATA(),
        .o_KEYMAP_WE(),
        .o_JOYMAP_WE(),
        .i_JOY_LEFT(left_joystick),
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

        .o_SPI_SS_FLASH_n(),
        .o_SPI_SS_SD1_n(),
        .o_SPI_SS_SD0_n(spi_sd0_select_n),
        .o_SPI_SCK(spi_clock),
        .o_SPI_MOSI(spi_mosi),
        .i_SPI_SD_MISO(spi_sd_miso),
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
        .o_RAM_A_REQ2(ram_a_cycle_request),
        .i_RAM_A_REQ_ALLOW(1'b0),
        .o_RAM_A_RD_n(ram_a_read_n),
        .i_RAM_A_DI(ram_a_read_data),
        .o_RAM_A_DO(ram_a_write_data),
        .o_RAM_A_CYCLE(),
        .o_RAM_A_RFSH(),
        // Active high. The port defaults to '1', which would hold the CPU.
        .i_CPU_WAIT(cpu_wait),

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

    // ------------------------------------------------------------ keyboard, SD
`ifdef NEXTTANG_ZXNEXT_IO
    // The core's own SPI master reaches the SD socket directly. Without a card,
    // the pulled-up MISO reads 0xff, as an empty socket does.
    assign sd_clk = spi_clock;
    assign sd_mosi = spi_mosi;
    assign sd_cs = spi_sd0_select_n;
    assign spi_sd_miso = sd_miso;

    wire usb_clock;
    wire usb_pll_locked;

    nexttang_console138k_usb_pll usb_pll (
        .clock_in(sys_clk), .clock_60(usb_clock), .locked(usb_pll_locked)
    );

    wire [1:0] usb1_type, usb2_type;
    wire [7:0] usb1_modifiers, usb2_modifiers;
    wire [7:0] usb1_key1, usb1_key2, usb1_key3, usb1_key4, usb1_key5, usb1_key6;
    wire [7:0] usb2_key1, usb2_key2, usb2_key3, usb2_key4, usb2_key5, usb2_key6;
    wire usb1_dm_out, usb1_dp_out, usb1_output_enable;
    wire usb2_dm_out, usb2_dp_out, usb2_output_enable;
    wire [9:0] usb1_rom_address, usb2_rom_address;
    wire [3:0] usb1_rom_data, usb2_rom_data;
    wire usb1_rom_enable, usb2_rom_enable;
    wire usb1_game_left, usb1_game_right, usb1_game_up, usb1_game_down;
    wire usb1_game_a, usb1_game_b, usb1_game_x, usb1_game_y;
    wire usb2_game_left, usb2_game_right, usb2_game_up, usb2_game_down;
    wire usb2_game_a, usb2_game_b, usb2_game_x, usb2_game_y;
    wire usb1_game_select, usb1_game_start, usb2_game_select, usb2_game_start;
    wire [3:0] usb1_game_extra, usb2_game_extra;

    // A device already plugged in when the FPGA loads keeps the address an
    // earlier host gave it, so it never answers this one and stays absent
    // until it is unplugged. Driving both lines low (SE0) for 30 ms at
    // start-up is a USB bus reset, which returns it to address 0. The hosts
    // come out of reset 10 ms before the lines are released, so they see the
    // device connect.
    localparam integer USB_HOST_RELEASE = 1200000;  // 20 ms at 60 MHz
    localparam integer USB_BUS_RELEASE = 1800000;   // 30 ms
    reg [20:0] usb_startup = 21'd0;
    wire usb_bus_reset = usb_startup < USB_BUS_RELEASE;
    wire usb_host_reset = !usb_pll_locked || usb_startup < USB_HOST_RELEASE;

    always @(posedge usb_clock or negedge usb_pll_locked) begin
        if (!usb_pll_locked)
            usb_startup <= 21'd0;
        else if (usb_bus_reset)
            usb_startup <= usb_startup + 1'b1;
    end

    assign usb1_dn = usb_bus_reset ? 1'b0 : usb1_output_enable ? usb1_dm_out : 1'bz;
    assign usb1_dp = usb_bus_reset ? 1'b0 : usb1_output_enable ? usb1_dp_out : 1'bz;
    assign usb2_dn = usb_bus_reset ? 1'b0 : usb2_output_enable ? usb2_dm_out : 1'bz;
    assign usb2_dp = usb_bus_reset ? 1'b0 : usb2_output_enable ? usb2_dp_out : 1'bz;

    // Either socket takes a keyboard or a gamepad.
    usb_hid_host #(
        .FULL_SPEED(1), .KEYBOARD_SUPPORT(1), .MOUSE_SUPPORT(0), .GAME_SUPPORT(1)
    ) usb_host_one (
        .clk(usb_clock), .reset(usb_host_reset), .cs(1'b1),
        .usb_dm_i(usb1_dn), .usb_dp_i(usb1_dp),
        .usb_dm_o(usb1_dm_out), .usb_dp_o(usb1_dp_out),
        .usb_oe(usb1_output_enable),
        .typ(usb1_type), .full_report(), .connerr(), .busy(),
        .key_modifiers(usb1_modifiers),
        .key_0(usb1_key1), .key_1(usb1_key2), .key_2(usb1_key3),
        .key_3(usb1_key4), .key_4(usb1_key5), .key_5(usb1_key6),
        .mouse_btn(), .mouse_dx(), .mouse_dy(),
        .game_l(usb1_game_left), .game_r(usb1_game_right),
        .game_u(usb1_game_up), .game_d(usb1_game_down),
        .game_a(usb1_game_a), .game_b(usb1_game_b),
        .game_x(usb1_game_x), .game_y(usb1_game_y),
        .game_sel(usb1_game_select), .game_sta(usb1_game_start),
        .game_extra(usb1_game_extra),
        .dbg_hid_report(), .dbg_hid_regs(), .dbg_byte_strobe(),
        .dbg_packet_valid(), .dbg_config_snapshot(),
        .dbg_config_snapshot_valid(), .dbg_full_speed(), .dbg_speed_sample(),
        .rom_addr(usb1_rom_address), .rom_dout(usb1_rom_data),
        .rom_en(usb1_rom_enable)
    );

    usb_hid_host #(
        .FULL_SPEED(1), .KEYBOARD_SUPPORT(1), .MOUSE_SUPPORT(0), .GAME_SUPPORT(1)
    ) usb_host_two (
        .clk(usb_clock), .reset(usb_host_reset), .cs(1'b1),
        .usb_dm_i(usb2_dn), .usb_dp_i(usb2_dp),
        .usb_dm_o(usb2_dm_out), .usb_dp_o(usb2_dp_out),
        .usb_oe(usb2_output_enable),
        .typ(usb2_type), .full_report(), .connerr(), .busy(),
        .key_modifiers(usb2_modifiers),
        .key_0(usb2_key1), .key_1(usb2_key2), .key_2(usb2_key3),
        .key_3(usb2_key4), .key_4(usb2_key5), .key_5(usb2_key6),
        .mouse_btn(), .mouse_dx(), .mouse_dy(),
        .game_l(usb2_game_left), .game_r(usb2_game_right),
        .game_u(usb2_game_up), .game_d(usb2_game_down),
        .game_a(usb2_game_a), .game_b(usb2_game_b),
        .game_x(usb2_game_x), .game_y(usb2_game_y),
        .game_sel(usb2_game_select), .game_sta(usb2_game_start),
        .game_extra(usb2_game_extra),
        .dbg_hid_report(), .dbg_hid_regs(), .dbg_byte_strobe(),
        .dbg_packet_valid(), .dbg_config_snapshot(),
        .dbg_config_snapshot_valid(), .dbg_full_speed(), .dbg_speed_sample(),
        .rom_addr(usb2_rom_address), .rom_dout(usb2_rom_data),
        .rom_en(usb2_rom_enable)
    );

    usb_hid_host_dual_rom usb_microcode (
        .clk(usb_clock),
        .addra(usb1_rom_address), .douta(usb1_rom_data), .ena(usb1_rom_enable),
        .addrb(usb2_rom_address), .doutb(usb2_rom_data), .enb(usb2_rom_enable)
    );

    wire [39:0] usb1_keys, usb2_keys;
    wire [4:0] usb1_kempston, usb2_kempston;

    nexttang_usb_keyboard_matrix usb1_key_decode (
        .device_type(usb1_type), .modifiers(usb1_modifiers),
        .key1(usb1_key1), .key2(usb1_key2), .key3(usb1_key3),
        .key4(usb1_key4), .key5(usb1_key5), .key6(usb1_key6), .keys(usb1_keys)
    );
    nexttang_usb_keyboard_matrix usb2_key_decode (
        .device_type(usb2_type), .modifiers(usb2_modifiers),
        .key1(usb2_key1), .key2(usb2_key2), .key3(usb2_key3),
        .key4(usb2_key4), .key5(usb2_key5), .key6(usb2_key6), .keys(usb2_keys)
    );
    nexttang_usb_gamepad_kempston usb1_game_decode (
        .device_type(usb1_type),
        .left(usb1_game_left), .right(usb1_game_right),
        .up(usb1_game_up), .down(usb1_game_down),
        .a(usb1_game_a), .b(usb1_game_b), .x(usb1_game_x), .y(usb1_game_y),
        .select_button(usb1_game_select), .start_button(usb1_game_start),
        .extra_buttons(usb1_game_extra), .joystick(usb1_kempston)
    );
    nexttang_usb_gamepad_kempston usb2_game_decode (
        .device_type(usb2_type),
        .left(usb2_game_left), .right(usb2_game_right),
        .up(usb2_game_up), .down(usb2_game_down),
        .a(usb2_game_a), .b(usb2_game_b), .x(usb2_game_x), .y(usb2_game_y),
        .select_button(usb2_game_select), .start_button(usb2_game_start),
        .extra_buttons(usb2_game_extra), .joystick(usb2_kempston)
    );

    // Key and joystick state crosses into the 28 MHz machine domain on two
    // flops. Each bit is independent, so a key changing mid-crossing is seen
    // at most one cycle late, never as a phantom key.
    reg [39:0] keys_meta = 40'b0;
    reg [39:0] keys_sync = 40'b0;
    reg [4:0] kempston_meta = 5'b0;
    reg [4:0] kempston_sync = 5'b0;

    always @(posedge clock_28) begin
        keys_meta <= usb1_keys | usb2_keys;
        keys_sync <= keys_meta;
        kempston_meta <= usb1_kempston | usb2_kempston;
        kempston_sync <= kempston_meta;
    end

    nexttang_keyboard_matrix keyboard_scan (
        .row_select(keyboard_rows),
        .keys(keys_sync),
        .columns(keyboard_columns)
    );

    // Kempston's fire, up, down, left and right already sit where the core's
    // joystick word puts B, U, D, L and R.
    assign left_joystick = {7'b0, kempston_sync};
    wire keyboard_connected = usb1_type == 2'd1 || usb2_type == 2'd1;
    wire input_active = |keys_sync || |kempston_sync;
`else
    assign keyboard_columns = 5'b11111;
    assign left_joystick = 12'b0;
    assign spi_sd_miso = 1'b1;
    wire keyboard_connected = 1'b0;
    wire input_active = 1'b0;
`endif

    // ---------------------------------------------------------- main memory
`ifdef NEXTTANG_ZXNEXT_DDR3
    // Machine-domain view of calibration. The clock tree already holds the
    // machine in reset until it rises; the service needs it in its own domain.
    reg memory_available_meta = 1'b0;
    reg memory_available = 1'b0;

    always @(posedge clock_28 or negedge machine_locked) begin
        if (!machine_locked) begin
            memory_available_meta <= 1'b0;
            memory_available <= 1'b0;
        end else begin
            memory_available_meta <= calibration_complete;
            memory_available <= memory_available_meta;
        end
    end

    wire line_request;
    wire line_ready;
    wire line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    wire line_response_valid;
    wire [127:0] line_read_data;

    nexttang_zxnext_memory_port main_memory (
        .machine_clock(clock_28),
        .machine_reset(machine_reset),
        .memory_available(memory_available),
        .core_request(ram_a_cycle_request),
        .core_read_n(ram_a_read_n),
        .core_address(ram_a_address),
        .core_write_data(ram_a_write_data),
        .core_read_data(ram_a_read_data),
        .core_wait(cpu_wait),
        .memory_clock(controller_clock),
        .memory_reset(!controller_reset_n),
        .line_request(line_request),
        .line_ready(line_ready),
        .line_write(line_write),
        .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .fault_timeout(fault_timeout),
        .fault_overrun(fault_overrun),
        .fault_calibration_lost(fault_calibration_lost)
    );

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

    nexttang_gowin_ddr3_ui_adapter memory_adapter (
        .clock(controller_clock),
        .reset(!controller_reset_n),
        .line_request(line_request),
        .line_ready(line_ready),
        .line_write(line_write),
        .line_address(line_address),
        .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
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
        .controller_burst(controller_burst)
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
        .sr_req(1'b0),
        .ref_req(1'b0),
        .sr_ack(self_refresh_acknowledge),
        .ref_ack(refresh_acknowledge),
        .burst(controller_burst),
        .O_ddr_addr(ddr_addr),
        .O_ddr_ba(ddr_bank),
        .O_ddr_cs_n(ddr_cs),
        .O_ddr_ras_n(ddr_ras),
        .O_ddr_cas_n(ddr_cas),
        .O_ddr_we_n(ddr_we),
        .O_ddr_clk(ddr_ck),
        .O_ddr_clk_n(ddr_ck_n),
        .O_ddr_cke(ddr_cke),
        .O_ddr_odt(ddr_odt),
        .O_ddr_reset_n(ddr_reset_n),
        .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq),
        .IO_ddr_dqs(ddr_dqs),
        .IO_ddr_dqs_n(ddr_dqs_n)
    );
`else
    // The core raises o_RAM_A_REQ for exactly one rising 28 MHz edge per
    // memory cycle, so a write lands once. Reads return one 28 MHz cycle after
    // the address, far inside the CPU's own read window at 3.5 MHz.
    wire ram_a_write = ram_a_request && ram_a_read_n;
    assign cpu_wait = 1'b0;

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
`endif

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
            if (ram_a_request && ram_a_read_n && ram_a_address[15:14] == 2'b10)
                test_window_write_seen <= 1'b1;
        end
    end

    // The core's HDMI window begins with 16 pixels of blanking, so the border
    // colour is sampled further in, at (24, 8), which is border in every mode.
    reg [8:0] border_rgb = 9'b0;
    reg frame_seen = 1'b0;
    reg lit_pixel_seen = 1'b0;

    always @(posedge clock_7) begin
        if (!machine_locked) begin
            border_rgb <= 9'b0;
            frame_seen <= 1'b0;
            lit_pixel_seen <= 1'b0;
        end else begin
            if (capture_frame_start)
                frame_seen <= 1'b1;
            if (capture_pixel_valid && capture_x == 9'd24 && capture_y == 9'd8)
                border_rgb <= capture_pixel;
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
    // Last opcode address, border colour, USB keyboard connected, any key or
    // joystick input held, capture and scaler faults, then the memory
    // service's timeout, overrun and calibration loss.
`ifdef NEXTTANG_ZXNEXT_DDR3
    wire [2:0] memory_faults = {fault_timeout, fault_overrun, fault_calibration_lost};
`else
    wire [2:0] memory_faults = 3'b0;
`endif
    wire [31:0] status_value = {
        opcode_address, border_rgb, keyboard_connected, input_active,
        capture_protocol_error, scaled_overrun, memory_faults
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
