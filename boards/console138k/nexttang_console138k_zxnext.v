// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// ZX Spectrum Next images for the Tang Console 138K.
//
// The pinned MiSTer ZXNext core runs on the machine clock tree with the
// project's diagnostic boot ROM in place of the excluded upstream one. The
// core's own HDMI window is captured at 7 MHz
// and scaled into the established 720p output, and the status UART reports how
// far the machine got without HDMI.
//
// Main memory depends on the profile. By default it is a 64 KiB block RAM
// standing in for the 2 MB SRAM space; addresses alias above it, which is
// enough for the diagnostic's 16 KiB test window at 0x8000 and nothing more.
// With NEXTTANG_ZXNEXT_DDR3 defined, the whole 2 MB space lives in DDR3
// behind the hardware-verified CPU memory service, and the machine is held in
// reset until the controller calibrates, and Layer 2 reads a block-RAM mirror
// of RAM banks 8 to 15. Without DDR3, Layer 2's memory port reads zero.
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
    input  wire       debug_uart_rx,
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
    wire cpu_wait;              // main memory not ready: the Z80 waits
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

    nexttang_console138k_machine_clock_tree #(
        .PLL_DIVIDERS(1)
    ) clock_tree (
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
    // The core asks for its own resets through NextREG 0x02 and restarts when
    // its video timing changes. The firmware soft-resets after loading the
    // machine ROMs, so without this it would never start them.
    wire       core_soft_reset_request;
    wire       core_hard_reset_request;
    wire [2:0] core_video_mode;
    wire       core_reset;
    wire       core_boot;

    nexttang_zxnext_core_reset core_resets (
        .clock_28(clock_28),
        .machine_reset(machine_reset),
        .soft_request(core_soft_reset_request),
        .hard_request(core_hard_reset_request),
        .video_mode(core_video_mode),
        .core_reset(core_reset),
        .core_boot(core_boot)
    );

    wire [20:0] ram_a_address;
    wire [20:0] layer2_address;
    wire [7:0]  layer2_data;
    wire        ram_a_request;
    wire        ram_a_cycle_request;
    wire [7:0]  keyboard_rows;
    wire [10:1] function_keys;   // F1-F10 for the core's hot keys
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
    wire        core_video_60;   // the core's 50/60 Hz setting: 1 for 60 Hz
    wire        core_hdmi_pixel;
    wire        core_hdmi_lock;
    wire        core_m1_n;
    wire        core_wr_n;
    wire        core_rd_n;
    wire [7:0]  core_bus_data;
    wire        core_nr_write;
    wire [7:0]  core_nr_register;
    wire [7:0]  core_nr_data;
    wire        core_iorq_n;
    wire [15:0] core_bus_address;
    wire [12:0] core_audio_left;
    wire [12:0] core_audio_right;

`ifdef NEXTTANG_ZXNEXT_DDR3
    // Layer 2 reads come from a block RAM mirror of 16 KiB banks 8 to 31:
    // the banks NextREG 0x12 and 0x13 reset to (8 and 11), each with room
    // for a 320x256 or 640x256 screen, and space above for games that keep
    // further screens there. SRAM unit = RAM bank + 16. The core shows
    // Layer 2 kept anywhere else as transparent. The frame store's move to
    // DDR3 made room for the 192 blocks this takes.
    localparam integer LAYER2_FIRST_A = 24;
    localparam integer LAYER2_BANKS_A = 24;
    localparam integer LAYER2_FIRST_B = 0;
    localparam integer LAYER2_BANKS_B = 0;
    localparam [127:0] LAYER2_UNITS =
        (((128'd1 << LAYER2_BANKS_A) - 128'd1) << LAYER2_FIRST_A) |
        (((128'd1 << LAYER2_BANKS_B) - 128'd1) << LAYER2_FIRST_B);
`else
    // Nothing serves Layer 2 here, so it is hidden everywhere.
    localparam [127:0] LAYER2_UNITS = 128'd0;
`endif

    zxnext #(
        .g_video_def(3'b000),
        .g_version(8'h32),
        .g_sub_version(8'h03),   // official core 3.02.03
        .g_video_inc(2'b10),
        .g_layer2_units(LAYER2_UNITS),
        .g_machine_id(8'h0A),
        .g_board_issue(4'h2)
    ) core (

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
        .i_RESET(core_reset),
        .i_BOOT(core_boot),
        .o_RESET_SOFT(core_soft_reset_request),
        .o_RESET_HARD(core_hard_reset_request),
        .o_RESET_PERIPHERAL(),
        .o_FLASH_BOOT(),
        .o_CORE_ID(),

        .i_SPKEY_FUNCTION(function_keys),   // F10 down to F1
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
        .o_RGB_VS_n(core_vsync_n),
        .o_RGB_BK_n(),
        .o_RGB_HS_n(),
        .o_VIDEO_50_60(core_video_60),
        .o_VIDEO_SCANLINES(),
        .o_VIDEO_SCANDOUBLE(),
        .o_VIDEO_MODE(core_video_mode),
        .o_MACHINE_TIMING(),
        .o_HDMI_RESET(),
        .o_HDMI_PIXEL(core_hdmi_pixel),
        .o_HDMI_LOCK(core_hdmi_lock),

        .o_AUDIO_HDMI_AUDIO_EN(),
        .o_AUDIO_SPEAKER_EN(),
        .o_AUDIO_SPEAKER_EXCL(),
        .i_AUDIO_EAR(1'b0),
        .o_AUDIO_MIC(),
        .o_AUDIO_EAR(),
        .o_AUDIO_L(core_audio_left),
        .o_AUDIO_R(core_audio_right),
        .o_AUDIO_PI_FE_EAR(),
        .o_AUDIO_ISSUE2_FE_MIC(),

        .o_RAM_A_ADDR(ram_a_address),
        .o_RAM_A_ADDR_21(),
        .o_RAM_A_REQ(ram_a_request),
        .o_RAM_A_REQ2(ram_a_cycle_request),
        .o_RAM_A_RD_n(ram_a_read_n),
        .i_RAM_A_DI(ram_a_read_data),
        .o_RAM_A_DO(ram_a_write_data),
        // Active high. The port defaults to '1', which would hold the CPU.
        .i_CPU_WAIT(cpu_wait),

        .o_RAM_B_ADDR(layer2_address),
        .o_RAM_B_REQ_T(),
        .i_RAM_B_DI(layer2_data),

        .o_BUS_ADDR(core_bus_address),
        .i_BUS_DI(8'hff),
        .o_BUS_DO(core_bus_data),
        .o_BUS_MREQ_n(),
        .o_BUS_IORQ_n(),
        .o_BUS_RD_n(core_rd_n),
        .o_BUS_WR_n(core_wr_n),
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
        .o_BUS_P3_MTR_n(),
        .o_BUS_P3_DRD_n(),
        .o_BUS_P3_DWR_n(),

        .i_ESP_GPIO_20(3'b111),
        .o_ESP_GPIO_0(),
        .o_ESP_GPIO_0_EN(),
        .i_GPIO(28'b0),
        .o_GPIO(),
        .o_GPIO_EN(),

        // The official core's Xilinx device DNA and XADC ports; the Gowin part
        // has neither.
        .o_XDNA_LOAD(),
        .o_XDNA_SHIFT(),
        .i_XDNA_DO(1'b0),
        .o_XADC_RESET(),
        .o_XADC_DEN(),
        .o_XADC_DADDR(),
        .o_XADC_DWE(),
        .i_XADC_DRDY(1'b0),
        .o_XADC_DI(),
        .i_XADC_DO(16'h0000),
        .i_XADC_BUSY(1'b0),
        .i_XADC_EOC(1'b0),
        .i_XADC_EOS(1'b0),
        .o_XADC_CONVST(),
        .o_XADC_CONTROL(),

        .o_DEBUG_NR_WE(core_nr_write),
        .o_DEBUG_NR_REG(core_nr_register),
        .o_DEBUG_NR_DAT(core_nr_data),
        .o_DEBUG_IORQ_n(core_iorq_n)
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
    wire [10:1] usb1_functions, usb2_functions;
    wire [4:0] usb1_kempston, usb2_kempston;

    nexttang_usb_keyboard_matrix usb1_key_decode (
        .device_type(usb1_type), .modifiers(usb1_modifiers),
        .key1(usb1_key1), .key2(usb1_key2), .key3(usb1_key3),
        .key4(usb1_key4), .key5(usb1_key5), .key6(usb1_key6), .keys(usb1_keys),
        .function_keys(usb1_functions)
    );
    nexttang_usb_keyboard_matrix usb2_key_decode (
        .device_type(usb2_type), .modifiers(usb2_modifiers),
        .key1(usb2_key1), .key2(usb2_key2), .key3(usb2_key3),
        .key4(usb2_key4), .key5(usb2_key5), .key6(usb2_key6), .keys(usb2_keys),
        .function_keys(usb2_functions)
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
    // Keys held from the host over the debug UART (K command below), in the
    // same order as the USB keyboards' and ORed with them.
    reg [39:0] host_keys = 40'b0;
    reg [4:0] kempston_meta = 5'b0;
    reg [4:0] kempston_sync = 5'b0;
    // F1-F10 for the core's hot keys (F1 hard reset, F3 50/60 Hz, F4 soft
    // reset, F8 CPU speed, F9 Multiface NMI, F10 divMMC NMI); the core acts on
    // a press, so a held key does not repeat.
    reg [10:1] host_functions = 10'b0;
    reg [10:1] functions_meta = 10'b0;
    reg [10:1] functions_sync = 10'b0;

    always @(posedge clock_28) begin
        keys_meta <= usb1_keys | usb2_keys | host_keys;
        keys_sync <= keys_meta;
        functions_meta <= usb1_functions | usb2_functions | host_functions;
        functions_sync <= functions_meta;
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
    assign function_keys = functions_sync;
    wire keyboard_connected = usb1_type == 2'd1 || usb2_type == 2'd1;
    wire input_active = |keys_sync || |kempston_sync;
`else
    assign keyboard_columns = 5'b11111;
    assign function_keys = 10'b0;
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

    nexttang_layer2_mirror #(
        .FIRST_A(LAYER2_FIRST_A),
        .BANKS_A(LAYER2_BANKS_A),
        .FIRST_B(LAYER2_FIRST_B),
        .BANKS_B(LAYER2_BANKS_B)
    ) layer2_memory (
        .clock_28(clock_28),
        .write_request(ram_a_cycle_request),
        .write_n_read(ram_a_read_n),
        .write_address(ram_a_address),
        .write_data(ram_a_write_data),
        .read_address(layer2_address),
        .read_data(layer2_data),
        .check_data(),
        .check_hit()
    );

    wire line_request;
    wire line_ready;
    wire line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    wire line_response_valid;
    wire [127:0] line_read_data;

    // A 16 KiB line cache answers most CPU and DMA reads in two cycles
    // instead of the 16 to 26 a DDR3 read takes.
    nexttang_zxnext_memory_port #(
        .CACHE(1)
    ) main_memory (
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

    // Each client's side of the arbiter. Read data goes to both; only the
    // granted client sees it marked valid.
    wire cpu_controller_request;
    wire cpu_controller_command_ready;
    wire [2:0] cpu_controller_command;
    wire cpu_controller_command_enable;
    wire [28:0] cpu_controller_address;
    wire cpu_controller_write_data_ready;
    wire [255:0] cpu_controller_write_data;
    wire cpu_controller_write_data_enable;
    wire cpu_controller_write_data_end;
    wire [31:0] cpu_controller_write_data_mask;
    wire cpu_controller_read_data_valid;
    wire cpu_controller_burst;
    wire video_controller_request;
    wire video_controller_command_ready;
    wire [2:0] video_controller_command;
    wire video_controller_command_enable;
    wire [28:0] video_controller_address;
    wire video_controller_write_data_ready;
    wire [255:0] video_controller_write_data;
    wire video_controller_write_data_enable;
    wire video_controller_write_data_end;
    wire [31:0] video_controller_write_data_mask;
    wire video_controller_read_data_valid;
    wire video_controller_burst;

    // Writes are posted: the CPU carries on as soon as the controller accepts
    // one, and the adapter lays still-draining writes over any read of their
    // line. Holding every write for the full drain cost the CPU 10 us a write.
    nexttang_gowin_ddr3_ui_adapter #(
        .POSTED_WRITES(1),
        .PENDING_LINES(8)
    ) memory_adapter (
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
        .controller_request(cpu_controller_request),
        .controller_command_ready(cpu_controller_command_ready),
        .controller_command(cpu_controller_command),
        .controller_command_enable(cpu_controller_command_enable),
        .controller_address(cpu_controller_address),
        .controller_write_data_ready(cpu_controller_write_data_ready),
        .controller_write_data(cpu_controller_write_data),
        .controller_write_data_enable(cpu_controller_write_data_enable),
        .controller_write_data_end(cpu_controller_write_data_end),
        .controller_write_data_mask(cpu_controller_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(cpu_controller_read_data_valid),
        .controller_burst(cpu_controller_burst)
    );

    // The HDMI frame store keeps its frames in DDR3 above the Next's 2 MiB
    // and shares the controller with the CPU, one transaction at a time.
    nexttang_ddr3_ui_arbiter memory_arbiter (
        .clock(controller_clock),
        .reset(!controller_reset_n),
        .a_request(cpu_controller_request),
        .a_command_ready(cpu_controller_command_ready),
        .a_command(cpu_controller_command),
        .a_command_enable(cpu_controller_command_enable),
        .a_address(cpu_controller_address),
        .a_write_data_ready(cpu_controller_write_data_ready),
        .a_write_data(cpu_controller_write_data),
        .a_write_data_enable(cpu_controller_write_data_enable),
        .a_write_data_end(cpu_controller_write_data_end),
        .a_write_data_mask(cpu_controller_write_data_mask),
        .a_read_data_valid(cpu_controller_read_data_valid),
        .a_burst(cpu_controller_burst),
        .b_request(video_controller_request),
        .b_command_ready(video_controller_command_ready),
        .b_command(video_controller_command),
        .b_command_enable(video_controller_command_enable),
        .b_address(video_controller_address),
        .b_write_data_ready(video_controller_write_data_ready),
        .b_write_data(video_controller_write_data),
        .b_write_data_enable(video_controller_write_data_enable),
        .b_write_data_end(video_controller_write_data_end),
        .b_write_data_mask(video_controller_write_data_mask),
        .b_read_data_valid(video_controller_read_data_valid),
        .b_burst(video_controller_burst),
        .controller_command_ready(controller_command_ready),
        .controller_command(controller_command),
        .controller_command_enable(controller_command_enable),
        .controller_address(controller_address),
        .controller_write_data_ready(controller_write_data_ready),
        .controller_write_data(controller_write_data),
        .controller_write_data_enable(controller_write_data_enable),
        .controller_write_data_end(controller_write_data_end),
        .controller_write_data_mask(controller_write_data_mask),
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
    assign layer2_data = 8'h00;

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
    // takes one whole pixel per sample. They change on the rising edge of
    // 14 MHz, which is also where 7 MHz rises, so a 7 MHz register taking them
    // directly would race the change: Layer 2's halves of a pixel can differ,
    // and pixels flickered to their right-hand neighbour's colour. They are
    // taken first on the falling edge of 14 MHz, halfway between changes, and
    // the 7 MHz register takes that copy, which is the same pixel without the
    // race.
    reg [8:0] midpoint_rgb = 9'b0;
    reg       midpoint_pixel = 1'b0;
    reg [8:0] sampled_rgb = 9'b0;
    reg       sampled_pixel = 1'b0;

    always @(negedge clock_14) begin
        midpoint_rgb <= core_rgb;
        midpoint_pixel <= core_hdmi_pixel;
    end

    always @(posedge clock_7) begin
        sampled_rgb <= midpoint_rgb;
        sampled_pixel <= midpoint_pixel;
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

    // 720p50 (CEA mode 19, 1980 x 750) while the core runs 50 Hz timing, and
    // 720p60 (CEA mode 4, 1650 x 750) while it runs 60 Hz, as the Next's own
    // F3 and NextREG 0x05 select. The modes share the pixel clock and differ
    // only in the horizontal front porch, so the output changes mode at a
    // frame boundary without touching the clocks; the frame store absorbs any
    // difference in rate. This board's pixel clock is 75 MHz, not 74.25, so
    // the outputs run at 50.5 and 60.6 Hz. The HDMI transmitter keeps its own
    // counters for the same frame and takes the mode from the timing module.
    localparam integer FRAME_WIDTH = 1980;
    localparam integer FRAME_HEIGHT = 750;

    reg [1:0] video_60_sync = 2'b00;
    wire output_60;

    always @(posedge pixel_clock)
        video_60_sync <= {video_60_sync[0], core_video_60};

    nexttang_video_timing #(
        .H_FRONT(440),
        .H_FRONT_ALT(110)
    ) timing (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .alt_select(video_60_sync[1]),
        .alt_active(output_60),
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

    // In 60 Hz timing the core's HDMI window is 360 x 240 instead of 360 x 288,
    // so frames captured then end 48 lines sooner and are shown centred.
    reg [1:0] capture_60_sync = 2'b00;

    always @(posedge clock_7)
        capture_60_sync <= {capture_60_sync[0], core_video_60};

    // DDR3 builds keep the three frames in DDR3, which leaves 171 block RAMs
    // free; the others keep them in block RAM.
`ifdef NEXTTANG_ZXNEXT_DDR3
    wire frame_store_late;
    // V0 from the debug UART stops the frame store's DDR3 traffic and V1
    // restarts it, so the CPU's wait for main memory can be measured with
    // and without it under one workload. The picture is stale while it is
    // off.
    reg video_memory_enable = 1'b1;
    reg [1:0] video_memory_sync = 2'b11;

    always @(posedge controller_clock)
        video_memory_sync <= {video_memory_sync[0], video_memory_enable};

    nexttang_ddr3_frame_store #(
        .PIXEL_BITS(9),
        .ALT_SOURCE_HEIGHT(240)
    ) scaler (
        .source_clock(clock_7),
        .source_reset(!machine_locked),
        .source_frame_start(capture_frame_start),
        .source_short(capture_60_sync[1]),
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
        .output_frame_valid(scaled_frame_valid),
        .memory_clock(controller_clock),
        .memory_reset(!controller_reset_n),
        .memory_available(calibration_complete && video_memory_sync[1]),
        .controller_request(video_controller_request),
        .controller_command_ready(video_controller_command_ready),
        .controller_command(video_controller_command),
        .controller_command_enable(video_controller_command_enable),
        .controller_address(video_controller_address),
        .controller_write_data_ready(video_controller_write_data_ready),
        .controller_write_data(video_controller_write_data),
        .controller_write_data_enable(video_controller_write_data_enable),
        .controller_write_data_end(video_controller_write_data_end),
        .controller_write_data_mask(video_controller_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(video_controller_read_data_valid),
        .controller_burst(video_controller_burst),
        .fetch_late(frame_store_late)
    );

    // A late line from DDR3 is reported with the frame store's overrun.
    reg [1:0] frame_store_late_sync = 2'b00;
    wire frame_store_fault = scaled_overrun || frame_store_late_sync[1];

    always @(posedge clock_7)
        frame_store_late_sync <= {frame_store_late_sync[0], frame_store_late};
`else
    nexttang_framebuffer_scaler #(
        .PIXEL_BITS(9),
        .ALT_SOURCE_HEIGHT(240)
    ) scaler (
        .source_clock(clock_7),
        .source_reset(!machine_locked),
        .source_frame_start(capture_frame_start),
        .source_short(capture_60_sync[1]),
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

    wire frame_store_fault = scaled_overrun;
`endif

    // The frame store's read multiplexer and the HDMI transmitter do not fit
    // one 75 MHz cycle together, so the pixel is registered once between
    // them.
    reg [8:0] output_pixel = 9'b0;

    always @(posedge pixel_clock)
        output_pixel <= scaled_pixel;

    // RGB333 to 8 bits per channel by repeating each field's bits.
    wire [7:0] red   = {output_pixel[8:6], output_pixel[8:6], output_pixel[8:7]};
    wire [7:0] green = {output_pixel[5:3], output_pixel[5:3], output_pixel[5:4]};
    wire [7:0] blue  = {output_pixel[2:0], output_pixel[2:0], output_pixel[2:1]};

    // ------------------------------------------------------------------ audio
    wire audio_ce;
    wire signed [15:0] audio_left;
    wire signed [15:0] audio_right;
    wire [15:0] audio_sample_words [1:0];

    nexttang_zxnext_audio_pcm audio_pcm (
        .core_clock(clock_28),
        .core_left(core_audio_left),
        .core_right(core_audio_right),
        .clock(pixel_clock),
        .reset(pixel_reset),
        .audio_ce(audio_ce),
        .left(audio_left),
        .right(audio_right)
    );

    assign audio_sample_words[0] = audio_left;
    assign audio_sample_words[1] = audio_right;

    // ------------------------------------------------------------------- HDMI
    // The transmitter wants each pixel one cycle after it shows the pixel's
    // position. The pixel reaching it left the timing counter four cycles
    // earlier (the timing module's registered position, the scaler's two
    // stages and the register above), so its counters start three pixels
    // behind the timing module's, which both leave reset with.
    wire [2:0] serial_data;
    wire hdmi_serial_clock;

    hdmi #(
        .VIDEO_ID_CODE(19),
        .VIDEO_REFRESH_RATE(50.0),
        .AUDIO_RATE(48000),
        .AUDIO_BIT_WIDTH(16),
        .VENDOR_NAME({"NextTang"}),
        .PRODUCT_DESCRIPTION({"ZX Spectrum Next", 8'd0}),
        .START_X(FRAME_WIDTH - 3),
        .START_Y(FRAME_HEIGHT - 1),
        .ALT_VIDEO_ID_CODE(4)
    ) hdmi_transmitter (
        .clk_pixel_x5(serial_clock),
        .clk_pixel(pixel_clock),
        .audio_ce(audio_ce),
        .reset(pixel_reset),
        // The timing module changes mode three pixels before this counter
        // wraps, so the transmitter takes the same frame's mode.
        .alt_mode(output_60),
        .rgb({red, green, blue}),
        .audio_sample_word(audio_sample_words),
        .tmds(serial_data),
        .tmds_clock(hdmi_serial_clock),
        .cx(),
        .cy(),
        .frame_width(),
        .frame_height(),
        .screen_width(),
        .screen_height()
    );

    ELVDS_OBUF clock_output (
        .I(hdmi_serial_clock), .O(tmds_clk_p), .OB(tmds_clk_n));
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
    // joystick input held, capture and frame store faults (a dropped frame, or
    // a line late from DDR3), then the memory service's timeout, overrun and
    // calibration loss.
`ifdef NEXTTANG_ZXNEXT_DDR3
    wire [2:0] memory_faults = {fault_timeout, fault_overrun, fault_calibration_lost};
`else
    wire [2:0] memory_faults = 3'b0;
`endif
    wire [31:0] status_value = {
        opcode_address, border_rgb, keyboard_connected, input_active,
        capture_protocol_error, frame_store_fault, memory_faults
    };

    wire status_transmit;
    wire trace_frozen;
    wire trace_transmit;

    // How much main memory holds the CPU, measured over windows of 2^24
    // 28 MHz cycles (0.6 s): the cycles held, the holds begun and the longest
    // hold, each reported for the last complete window.
    reg [23:0] wait_window = 24'd0;
    reg [23:0] wait_window_cycles = 24'd0;
    reg [15:0] wait_window_holds = 16'd0;
    reg [15:0] wait_window_longest = 16'd0;
    reg [15:0] wait_hold_cycles = 16'd0;
    reg        cpu_wait_previous = 1'b0;
    reg [23:0] wait_cycles_reported = 24'd0;
    reg [15:0] wait_holds_reported = 16'd0;
    reg [15:0] wait_longest_reported = 16'd0;

    always @(posedge clock_28) begin
        cpu_wait_previous <= cpu_wait;
        wait_window <= wait_window + 24'd1;
        if (cpu_wait) begin
            if (wait_hold_cycles != 16'hffff)
                wait_hold_cycles <= wait_hold_cycles + 16'd1;
        end else begin
            wait_hold_cycles <= 16'd0;
        end

        if (wait_window == 24'hffffff) begin
            wait_cycles_reported <= wait_window_cycles;
            wait_holds_reported <= wait_window_holds;
            wait_longest_reported <= wait_window_longest;
            wait_window_cycles <= 24'd0;
            wait_window_holds <= 16'd0;
            wait_window_longest <= 16'd0;
        end else begin
            if (cpu_wait)
                wait_window_cycles <= wait_window_cycles + 24'd1;
            if (cpu_wait && !cpu_wait_previous && wait_window_holds != 16'hffff)
                wait_window_holds <= wait_window_holds + 16'd1;
            if (cpu_wait && wait_hold_cycles >= wait_window_longest)
                wait_window_longest <= wait_hold_cycles + 16'd1;
        end
    end

    // Whether the CPU is moving: a running count of its rising clock enables
    // (it stops if contention or main memory holds the CPU for good), and how
    // often the joystick input changes, which a boot-time check may be
    // waiting to see settle.
    reg [15:0] cpu_enable_count = 16'd0;
    reg [11:0] joystick_changes = 12'd0;
`ifdef NEXTTANG_ZXNEXT_IO
    reg [4:0]  joystick_previous = 5'b0;
`endif

    always @(posedge clock_28) begin
        if (cpu_rising_enable)
            cpu_enable_count <= cpu_enable_count + 16'd1;
`ifdef NEXTTANG_ZXNEXT_IO
        joystick_previous <= kempston_sync;
        if (kempston_sync != joystick_previous && joystick_changes != 12'hfff)
            joystick_changes <= joystick_changes + 12'd1;
`endif
    end

    // Interrupt acknowledges (IORQ with M1) less than 7 ms after the previous
    // one: at 50 or 60 Hz that means one interrupt was taken twice.
    reg [11:0] double_interrupts = 12'd0;
    reg [17:0] since_acknowledge = 18'h3ffff;
    reg        acknowledge_previous = 1'b0;

    always @(posedge clock_28) begin
        acknowledge_previous <= !core_iorq_n && !core_m1_n;
        if (!core_iorq_n && !core_m1_n && !acknowledge_previous) begin
            if (since_acknowledge < 18'd196000 && double_interrupts != 12'hfff)
                double_interrupts <= double_interrupts + 12'd1;
            since_acknowledge <= 18'd0;
        end else if (since_acknowledge != 18'h3ffff) begin
            since_acknowledge <= since_acknowledge + 18'd1;
        end
    end

    // Every byte the SD card sends: MISO shifted in on each rising SCK while
    // the card is selected, counted and summed, so boots that read the same
    // files can be compared.
    reg [23:0] sd_byte_count = 24'd0;
    reg [31:0] sd_checksum = 32'd0;
`ifdef NEXTTANG_ZXNEXT_IO
    reg        sd_clock_previous = 1'b0;
    reg        sd_miso_previous = 1'b1;
    reg [2:0]  sd_bit_count = 3'd0;
    reg [7:0]  sd_shift = 8'd0;

    always @(posedge clock_28) begin
        sd_clock_previous <= spi_clock;
        sd_miso_previous <= sd_miso;
        if (spi_sd0_select_n) begin
            sd_bit_count <= 3'd0;
        end else if (spi_clock && !sd_clock_previous) begin
            sd_shift <= {sd_shift[6:0], sd_miso_previous};
            sd_bit_count <= sd_bit_count + 3'd1;
            // 0xff is what the card sends while it has nothing to say, and how
            // many of those come varies, so they are left out.
            if (sd_bit_count == 3'd7 && {sd_shift[6:0], sd_miso_previous} != 8'hff) begin
                sd_byte_count <= sd_byte_count + 24'd1;
                sd_checksum <= sd_checksum + {24'd0, sd_shift[6:0], sd_miso_previous};
            end
        end
    end
`endif

    // The last I/O port the CPU read and the last it wrote, with the value
    // written, to show what a polling loop is waiting on. Interrupt
    // acknowledge cycles (IORQ with M1) are not counted.
    reg [15:0] last_io_read_port = 16'h0000;
    reg [15:0] last_io_write_port = 16'h0000;
    reg [7:0]  last_io_write_data = 8'h00;

    always @(posedge clock_28) begin
        if (!core_iorq_n && core_m1_n && !core_rd_n)
            last_io_read_port <= core_bus_address;
        if (!core_iorq_n && core_m1_n && !core_wr_n) begin
            last_io_write_port <= core_bus_address;
            last_io_write_data <= core_bus_data;
        end
    end


    // Which phase 7 MHz rises at against 14 MHz, seen on the falling edge of
    // 28 MHz, when both are steady: bit 3 when 14 MHz was high as 7 MHz rose
    // (the phase the core assumes), bit 2 when it was low. Sticky.
    reg [3:0] divider_phase = 4'b0000;
    reg       clock_7_seen = 1'b0;

    always @(negedge clock_28) begin
        clock_7_seen <= clock_7;
        if (clock_7 && !clock_7_seen)
            divider_phase <= divider_phase | (clock_14 ? 4'b1000 : 4'b0100);
    end

    nexttang_debug_status_uart #(
        .CLOCK_HZ(7000000),
        .GAP_CLOCKS(1750000),
        .EXTRA_VALUE(5)
    ) status_uart (
        .clock(clock_7),
        .reset(!machine_locked),
        .flags(status_flags),
        .value(status_value),
        .extra({
            wait_holds_reported, wait_longest_reported,
            8'h00, wait_cycles_reported,
            last_io_write_data, sd_byte_count,
            sd_checksum,
            cpu_wait, cpu_contend, 2'b00, double_interrupts, cpu_enable_count
        }),
        .transmit(status_transmit)
    );

    // Instruction-fetch history. It freezes after the CPU's first NMI, which is
    // how NextZXOS reports access to missing hardware, and then takes over the
    // UART to send what led up to it.
    // Commands from the host on the debug UART's other wire: F freezes the
    // fetch trace now, R re-arms it, and T followed by four hex digits sets the
    // address whose fetch freezes it, and re-arms.
    wire [7:0] command_byte;
    wire command_valid;

    nexttang_uart_receiver #(
        .CLOCK_HZ(28000000),
        .BAUD_RATE(115200)
    ) command_receiver (
        .clock(clock_28),
        .reset(!machine_locked),
        .receive(debug_uart_rx),
        .data(command_byte),
        .data_valid(command_valid)
    );

    reg [2:0]  trigger_digits_left = 3'd0;
    reg [15:0] trigger_command_address = 16'h0000;
    reg        trigger_command_done = 1'b0;
    wire       command_is_digit = (command_byte >= "0" && command_byte <= "9") ||
                                  (command_byte >= "a" && command_byte <= "f");
    wire [3:0] command_digit = command_byte <= "9" ? command_byte[3:0]
                                                   : command_byte[3:0] + 4'd9;

    // K followed by ten hex digits holds the given keys, a 40-bit mask in the
    // keyboard matrix's order (row * 5 + column), until the next K.
    reg [3:0]  key_digits_left = 4'd0;
    reg [39:0] key_command_mask = 40'b0;
    // J followed by three hex digits holds function keys, bit 0 for F1, until
    // the next J.
    reg [1:0]  function_digits_left = 2'd0;
    reg [11:0] function_command_mask = 12'b0;

    always @(posedge clock_28) begin
        if (command_valid) begin
            if (command_byte == "K") begin
                key_digits_left <= 4'd10;
            end else if (key_digits_left != 4'd0 && command_is_digit) begin
                key_command_mask <= {key_command_mask[35:0], command_digit};
                key_digits_left <= key_digits_left - 4'd1;
`ifdef NEXTTANG_ZXNEXT_IO
                if (key_digits_left == 4'd1)
                    host_keys <= {key_command_mask[35:0], command_digit};
`endif
            end else begin
                key_digits_left <= 4'd0;
            end

            if (command_byte == "J") begin
                function_digits_left <= 2'd3;
            end else if (function_digits_left != 2'd0 && command_is_digit) begin
                function_command_mask <= {function_command_mask[7:0], command_digit};
                function_digits_left <= function_digits_left - 2'd1;
`ifdef NEXTTANG_ZXNEXT_IO
                if (function_digits_left == 2'd1)
                    host_functions <= {function_command_mask[5:0], command_digit};
`endif
            end else begin
                function_digits_left <= 2'd0;
            end
        end
    end

`ifdef NEXTTANG_ZXNEXT_DDR3
    reg video_command = 1'b0;

    always @(posedge clock_28) begin
        if (command_valid) begin
            video_command <= command_byte == "V";
            if (video_command && (command_byte == "0" || command_byte == "1"))
                video_memory_enable <= command_byte[0];
        end
    end
`endif

    always @(posedge clock_28) begin
        trigger_command_done <= 1'b0;
        if (command_valid) begin
            if (command_byte == "T") begin
                trigger_digits_left <= 3'd4;
            end else if (trigger_digits_left != 3'd0 && command_is_digit) begin
                trigger_command_address <= {trigger_command_address[11:0], command_digit};
                trigger_digits_left <= trigger_digits_left - 3'd1;
                if (trigger_digits_left == 3'd1)
                    trigger_command_done <= 1'b1;
            end else begin
                trigger_digits_left <= 3'd0;
            end
        end
    end

    nexttang_m1_trace fetch_trace (
        .clock(clock_28),
        .reset(!machine_locked),
        .m1_n(core_m1_n),
        .address(core_bus_address),
        .freeze_request(command_valid && command_byte == "F"),
        .rearm_request(command_valid && command_byte == "R"),
        .set_trigger(trigger_command_done),
        .new_trigger(trigger_command_address),
        .frozen(trace_frozen),
        .transmit(trace_transmit)
    );

    // Every couple of seconds, between status lines, the NextREGs and the
    // video and paging ports as software last wrote them.
    wire log_sending;
    wire log_transmit;

    nexttang_nextreg_log nextreg_log (
        .clock(clock_28),
        .reset(!machine_locked),
        .nr_write(core_nr_write),
        .nr_register(core_nr_register),
        .nr_data(core_nr_data),
        .iorq_n(core_iorq_n),
        .wr_n(core_wr_n),
        .m1_n(core_m1_n),
        .address(core_bus_address),
        .data(core_bus_data),
        .other_transmit(status_transmit),
        .sending(log_sending),
        .transmit(log_transmit)
    );

    // The bytes last read from divMMC RAM bank 1 (SRAM page 0x11), which holds
    // code NextZXOS calls during boot; D on the command wire dumps them.
    wire capture_sending;
    wire capture_transmit;

    nexttang_memory_capture divmmc_capture (
        .clock(clock_28),
        .reset(!machine_locked),
        .read_done(ram_a_cycle_request && !ram_a_read_n && !cpu_wait),
        .read_address(ram_a_address),
        .read_data(ram_a_read_data),
        .dump_request(command_valid && command_byte == "D"),
        .sending(capture_sending),
        .transmit(capture_transmit)
    );

    assign debug_uart_tx = capture_sending ? capture_transmit
                         : trace_frozen ? trace_transmit
                         : log_sending ? log_transmit
                         : status_transmit;
endmodule

`default_nettype wire
