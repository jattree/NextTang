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
    wire memory_wait;           // DDR3 main memory's part of it
    wire port_a_wait;           // that, as port A sees it through the port C mux
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

    // Port C: the official Pi debug slave's main-memory port (core 3.02.04 on).
    wire [20:0] ram_c_address;
    wire        ram_c_request;
    wire        ram_c_read_n;
    wire [7:0]  ram_c_write_data;
    wire [7:0]  ram_c_read_data;
    wire        ram_c_ack;
    wire        ram_c_busy;
    // The Pi debug slave's SPI pins, driven by the FPGA's own master below.
    wire        pi_spi_ce_n;
    wire        pi_spi_sclk;
    wire        pi_spi_mosi;
    wire [27:0] core_gpio;
    // Hardware breakpoints (rtl/debug/nexttang_breakpoints.vhd).
    wire [15:0] cpu_next_pc;
    wire        cpu_stopped;
    wire        cpu_break;
    wire [63:0] core_mmu;

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

    // The official core's build options (zxnext.vhd, g_option): the CPU with
    // the debug interface (bits 1:0 = 10), the Pi debug slave with every
    // command (bits 4 to 12) and, with DDR3, port C for its main-memory
    // commands (bits 8 and 13). Without DDR3 there is no main memory to
    // share, so the memory commands are left out.
`ifdef NEXTTANG_ZXNEXT_DDR3
    localparam [15:0] CORE_OPTION = 16'hFFF2;   // as official issue 4 and 5
`else
    localparam [15:0] CORE_OPTION = 16'hDEF2;
`endif
    // Spec256: the CPU as the graphical lanes follow it (observation only).
    wire        s256_cpu_reset_n, s256_m1_n, s256_mreq_n, s256_iorq_n, s256_rd_n, s256_wr_n;
    wire        s256_wait_n, s256_int_n, s256_nmi_n, s256_busrq_n;
    wire [7:0]  s256_ir, s256_vector, s256_di, s256_i, s256_r, s256_f;
    wire [15:0] s256_a, s256_pc, s256_sp;
    wire [159:0] s256_regs;
    wire        s256_iff1, s256_iff2, s256_halted, s256_int_cycle, s256_nmi_cycle;
    wire        s256_boundary, s256_incdecz;
    wire [1:0]  s256_imode, s256_xy;
    // The planes, the colour mode and the host loader (DDR3 builds).
    wire        spec256_mode;
    reg         spec256_graphics = 1'b0;
    wire        spec256_desync;
    // The loader is also the CPU's: NextREG 0x3E takes its bytes and 0x3F
    // claims it, aborts it and reads its status (see the loader below).
    wire [7:0]  spec256_nr_status;
    localparam [7:0] SPEC256_NR_ID = 8'hA1;
    reg         spec256_cpu_owned = 1'b0;
    reg         spec256_abort = 1'b0;
    wire        spec256_payload;
    wire [127:0] spec256_lane_address;
    wire        spec256_lane_write;
    wire [63:0] spec256_lane_write_data;
    wire [63:0] spec256_plane_read;
    wire [63:0] spec256_lane_read;
    wire [15:0] spec256_overlay_address;
    wire [63:0] spec256_overlay_data;
    wire [7:0]  spec256_rules_flags;
    wire        spec256_background_present;
    wire        spec256_background_write;
    wire [15:0] spec256_background_address;
    wire [7:0]  spec256_background_index;
    wire [1:0]  spec256_background_image;
    wire [3:0]  spec256_backgrounds_present;
    wire        spec256_bgx_clear;
    wire        spec256_bgx_write;
    wire [9:0]  spec256_bgx_index;
    wire [7:0]  spec256_bgx_data;
    wire [2:0]  spec256_plane_bank;
    wire [7:0]  spec256_banks_with_planes;
    // What the overlay's background memory takes and shows (below).
    wire        overlay_background_write;
    wire [15:0] overlay_background_address;
    wire [7:0]  overlay_background_index;
    wire        overlay_background_shown;
    wire [23:0] spec256_cfg;
    wire [511:0] spec256_rules;
    wire [2:0]  spec256_zxpoly_mode;
    wire [8:0]  s256_ula_vc;
    wire [8:0]  s256_ula_hc;
    wire [7:0]  spec256_paper_trim;
    wire [63:0] s256_mmu;
    wire        s256_ula_shadow;
    wire        s256_retn;
    wire        s256_bank5_write;
    wire [13:0] s256_bank5_address;
    wire [7:0]  s256_bank5_data;

    zxnext #(
        .g_video_def(3'b000),
        .g_version(8'h32),
        .g_sub_version(8'h05),   // official core 3.02.05
        .g_video_inc(2'b10),
        .g_layer2_units(LAYER2_UNITS),
        .g_machine_id(8'h0A),
        .g_board_issue(4'h2),
        .g_option(CORE_OPTION)
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
        .i_SPKEY_FUNCTION_EXT(5'b0),

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

        .o_RAM_C_ADDR(ram_c_address),
        .o_RAM_C_REQ(ram_c_request),
        .o_RAM_C_RD_n(ram_c_read_n),
        .i_RAM_C_DI(ram_c_read_data),
        .o_RAM_C_DO(ram_c_write_data),
        .i_RAM_C_ACK(ram_c_ack),

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
        // GPIO 8 to 11 carry the Pi debug slave's SPI (CE0, MISO, MOSI, SCLK).
        // The slave is opened without NextREG 0xA0 so the debugger works
        // whatever the Next's software has set.
        .i_GPIO({16'b0, pi_spi_sclk, pi_spi_mosi, 1'b0, pi_spi_ce_n, 8'b0}),
        .i_PI_SPI_SLAVE_FORCE(1'b1),
        .o_CPU_NEXT_PC(cpu_next_pc),
        .o_CPU_STOPPED(cpu_stopped),
        .i_CPU_BREAK(cpu_break),
        .o_MMU(core_mmu),
        .o_GPIO(core_gpio),
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
        .o_DEBUG_IORQ_n(core_iorq_n),

        .o_SPEC256_CPU_RESET_n(s256_cpu_reset_n),
        .o_SPEC256_CPU_M1_n(s256_m1_n),
        .o_SPEC256_CPU_MREQ_n(s256_mreq_n),
        .o_SPEC256_CPU_IORQ_n(s256_iorq_n),
        .o_SPEC256_CPU_RD_n(s256_rd_n),
        .o_SPEC256_CPU_WR_n(s256_wr_n),
        .o_SPEC256_CPU_WAIT_n(s256_wait_n),
        .o_SPEC256_CPU_INT_n(s256_int_n),
        .o_SPEC256_CPU_NMI_n(s256_nmi_n),
        .o_SPEC256_CPU_BUSRQ_n(s256_busrq_n),
        .o_SPEC256_IR(s256_ir),
        .o_SPEC256_VECTOR(s256_vector),
        .o_SPEC256_DI(s256_di),
        .o_SPEC256_CPU_A(s256_a),
        .o_SPEC256_PC(s256_pc),
        .o_SPEC256_SP(s256_sp),
        .o_SPEC256_I(s256_i),
        .o_SPEC256_R(s256_r),
        .o_SPEC256_F(s256_f),
        .o_SPEC256_REGS(s256_regs),
        .o_SPEC256_IFF1(s256_iff1),
        .o_SPEC256_IFF2(s256_iff2),
        .o_SPEC256_HALTED(s256_halted),
        .o_SPEC256_IMODE(s256_imode),
        .o_SPEC256_XY(s256_xy),
        .o_SPEC256_INT_CYCLE(s256_int_cycle),
        .o_SPEC256_NMI_CYCLE(s256_nmi_cycle),
        .o_SPEC256_BOUNDARY(s256_boundary),
        .o_SPEC256_INCDECZ(s256_incdecz),
        .o_SPEC256_BANK5_WE(s256_bank5_write),
        .o_SPEC256_BANK5_A(s256_bank5_address),
        .o_SPEC256_BANK5_D(s256_bank5_data),
        .o_SPEC256_ULA_VC(s256_ula_vc),
        .o_SPEC256_ULA_HC(s256_ula_hc),
        .o_SPEC256_MMU(s256_mmu),
        .o_SPEC256_ULA_SHADOW(s256_ula_shadow),
        .o_SPEC256_RETN(s256_retn),
        .i_SPEC256_NR_3E(SPEC256_NR_ID),
        .i_SPEC256_NR_3F(spec256_nr_status)
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
    wire usb1_connerr, usb2_connerr, usb1_connected, usb2_connected;
    wire usb1_report, usb2_report;
    wire [63:0] usb1_hid_report;    // the socket 1 device's last report, byte 0 lowest
    wire [63:0] usb1_trace;         // socket 1's enumeration trace
    wire [3:0]  usb1_data0_handshake;  // socket 1's answer to the last SETUP data
    wire [3:0]  usb1_idle_states;      // socket 1's raw idle line states seen

    // USB diagnostics for the status line, per socket: a protocol error was
    // ever seen, the host has reached report polling, the device type, and
    // a count of reports received. They tell a device that never enumerates
    // from one whose reports arrive but are not decoded.
    reg       usb1_error_seen = 1'b0, usb2_error_seen = 1'b0;
    reg [7:0] usb1_reports = 8'd0, usb2_reports = 8'd0;
    always @(posedge usb_clock) begin
        if (usb1_connerr) usb1_error_seen <= 1'b1;
        if (usb2_connerr) usb2_error_seen <= 1'b1;
        if (usb1_report) usb1_reports <= usb1_reports + 1'b1;
        if (usb2_report) usb2_reports <= usb2_reports + 1'b1;
    end
    wire [31:0] usb_diagnostics = {
        usb1_error_seen, usb1_connected, usb1_type,
        usb2_error_seen, usb2_connected, usb2_type,
        usb1_reports, usb2_reports, usb1_data0_handshake, usb1_idle_states
    };
    // Socket 1's enumeration trace (see usb_hid_host dbg_trace). It changes
    // only on enumeration events, so the two-flop crossing into clock_7 is
    // enough.
    wire [63:0] usb_debug_word = usb1_trace;

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
        .typ(usb1_type), .full_report(), .connerr(usb1_connerr), .busy(),
        .link_connected(usb1_connected), .report_seen(usb1_report),
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
        .dbg_hid_report(usb1_hid_report), .dbg_hid_regs(), .dbg_byte_strobe(),
        .dbg_packet_valid(), .dbg_config_snapshot(),
        .dbg_config_snapshot_valid(), .dbg_full_speed(), .dbg_speed_sample(),
        .dbg_trace(usb1_trace), .dbg_watchdog_pc(),
        .dbg_data0_handshake(usb1_data0_handshake),
        .dbg_idle_states(usb1_idle_states),
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
        .typ(usb2_type), .full_report(), .connerr(usb2_connerr), .busy(),
        .link_connected(usb2_connected), .report_seen(usb2_report),
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
    // A Kempston joystick held from the host (N command below): bit 0 right,
    // 1 left, 2 down, 3 up, 4 fire, ORed with the USB pads'.
    reg [4:0] host_kempston = 5'b0;
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
        kempston_meta <= usb1_kempston | usb2_kempston | host_kempston;
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
    wire [31:0] usb_diagnostics = 32'd0;
    wire [63:0] usb_debug_word = 64'd0;
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

    // Port C joins port A here, ahead of the Layer 2 mirror and the cache, so
    // a debugger write updates every copy of the byte as a CPU write does.
    wire        memory_request;
    wire        memory_read_n;
    wire [20:0] memory_address;
    wire [7:0]  memory_write_data;
    wire [7:0]  memory_read_data;

    nexttang_zxnext_port_c_mux port_c_mux (
        .clock(clock_28),
        .reset(machine_reset),
        .a_request(ram_a_cycle_request),
        .a_read_n(ram_a_read_n),
        .a_address(ram_a_address),
        .a_write_data(ram_a_write_data),
        .a_wait(port_a_wait),
        .c_request(ram_c_request),
        .c_read_n(ram_c_read_n),
        .c_address(ram_c_address),
        .c_write_data(ram_c_write_data),
        .c_ack(ram_c_ack),
        .c_read_data(ram_c_read_data),
        .down_request(memory_request),
        .down_read_n(memory_read_n),
        .down_address(memory_address),
        .down_write_data(memory_write_data),
        .down_wait(memory_wait),
        .down_read_data(memory_read_data),
        .c_busy(ram_c_busy)
    );

    assign ram_a_read_data = memory_read_data;

    // The mirror copies main-memory writes a 28 MHz cycle late: a write's
    // request is held for several cycles and repeated on each, so the byte
    // kept is still the one present when the request ends, and the CPU's
    // write strobe, now through the port C mux, gets a whole clock to reach
    // the mirror's memories (as spec256-next a3012e8 does for its lanes).
    reg        layer2_write_request = 1'b0;
    reg        layer2_write_n_read = 1'b1;
    reg [20:0] layer2_write_address = 21'd0;
    reg [7:0]  layer2_write_data = 8'd0;
    always @(posedge clock_28) begin
        layer2_write_request <= memory_request;
        layer2_write_n_read <= memory_read_n;
        layer2_write_address <= memory_address;
        layer2_write_data <= memory_write_data;
    end

    nexttang_layer2_mirror #(
        .FIRST_A(LAYER2_FIRST_A),
        .BANKS_A(LAYER2_BANKS_A),
        .FIRST_B(LAYER2_FIRST_B),
        .BANKS_B(LAYER2_BANKS_B)
    ) layer2_memory (
        .clock_28(clock_28),
        .write_request(layer2_write_request),
        .write_n_read(layer2_write_n_read),
        .write_address(layer2_write_address),
        .write_data(layer2_write_data),
        .read_address(layer2_address),
        .read_data(layer2_data),
        .check_data(),
        .check_hit(),
        .spec256_mode(spec256_mode),
        .lane_address(spec256_lane_address),
        .lane_write(spec256_lane_write),
        .lane_write_data(spec256_lane_write_data),
        .lane_read_data(spec256_plane_read),
        .overlay_address(spec256_overlay_address),
        .overlay_data(spec256_overlay_data)
    );

    // ------------------------------------------------------------- Spec256
    // Eight graphical CPUs beside the core's, in lockstep: they follow it
    // from reset as exact copies, and from a game's first instruction take
    // their data from the colour planes in the mirror. The host loads the
    // planes and the palette over the debug UART (S, W, Q) and arms colour
    // mode at the game's start address (G); H turns it off. Colour mode needs
    // 14 MHz or below; Spec256 games run at 3.5.
    wire [127:0] lanes_address;
    // Which 8K slots have planes behind them, and where (below).
    reg [7:0]  spec256_slot_present = 8'hfc;
    reg [7:0]  spec256_slot_ddr3 = 8'h00;   // planes in DDR3 (below)
    reg [23:0] spec256_slot_high = 24'o76543210;
    wire [63:0]  lanes_write_data;
    wire [7:0]   lanes_write;
    wire         loader_plane_write;
    wire [15:0]  loader_plane_address;
    wire [63:0]  loader_plane_data;
    wire         loader_arm, loader_disarm;
    wire [15:0]  loader_arm_pc;
    wire         spec256_palette_write;
    wire [7:0]   spec256_palette_index;
    wire [8:0]   spec256_palette_rgb;

    nexttang_zxnext_spec256_lanes spec256_lanes (
        .clock_28(clock_28),
        .cen_r(cpu_rising_enable),
        .cen_f(cpu_falling_enable),
        .reset_n(s256_cpu_reset_n),
        .graphics(spec256_graphics),
        .master_control(1'b1),
        .rom_planes(spec256_rom_planes),
        .arith_mono(spec256_rules_flags[1]),
        .rules(spec256_rules),
        .plane_present(spec256_slot_present | spec256_slot_ddr3),
        .master_m1_n(s256_m1_n),
        .master_mreq_n(s256_mreq_n),
        .master_iorq_n(s256_iorq_n),
        .master_rd_n(s256_rd_n),
        .master_wr_n(s256_wr_n),
        .master_wait_n(s256_wait_n),
        .master_int_n(s256_int_n),
        .master_nmi_n(s256_nmi_n),
        .master_busrq_n(s256_busrq_n),
        .master_a(s256_a),
        .master_ir(s256_ir),
        .master_vector(s256_vector),
        .master_di(s256_di),
        .master_pc(s256_pc),
        .master_sp(s256_sp),
        .master_i(s256_i),
        .master_r(s256_r),
        .master_f(s256_f),
        .master_regs(s256_regs),
        .master_iff1(s256_iff1),
        .master_iff2(s256_iff2),
        .master_halted(s256_halted),
        .master_imode(s256_imode),
        .master_xy(s256_xy),
        .master_int_cycle(s256_int_cycle),
        .master_nmi_cycle(s256_nmi_cycle),
        .master_instruction_boundary(s256_boundary),
        .master_incdecz(s256_incdecz),
        .graphics_address(lanes_address),
        .graphics_data_in(spec256_lane_read),
        .graphics_data_out(lanes_write_data),
        .graphics_write(lanes_write),
        .graphics_iorq(),
        .desync(spec256_desync),
        .debug_lane_pc(),
        .debug_lane_regs()
    );

    // A game's coloured ROM character set (the .256's GRX1 block), 0x3D00 to
    // 0x3FFF, which the loader writes like plane words. It is read like the
    // mirror, the word for the address of the previous edge; until a font is
    // loaded, or after H or S0, the lanes take the master's ROM byte.
    reg [63:0] spec256_rom_font [0:767];
    reg [63:0] spec256_rom_font_q = 64'd0;
    reg        spec256_rom_font_hit = 1'b0;
    reg        spec256_rom_planes = 1'b0;
    wire       loader_font_write = loader_plane_write &&
                                   loader_plane_address[15:8] >= 8'h3d &&
                                   loader_plane_address[15:8] <= 8'h3f;
    wire [9:0] loader_font_index = loader_plane_address[9:0] - 10'h100;
    wire [9:0] lane_font_index = lanes_address[9:0] - 10'h100;

    always @(posedge clock_28) begin
        if (loader_font_write)
            spec256_rom_font[loader_font_index] <= loader_plane_data;
        spec256_rom_font_q <= spec256_rom_font[lane_font_index];
        spec256_rom_font_hit <= lanes_address[15:8] >= 8'h3d && lanes_address[15:8] <= 8'h3f;
        if (!spec256_mode || loader_disarm)
            spec256_rom_planes <= 1'b0;
        else if (loader_font_write)
            spec256_rom_planes <= 1'b1;
    end

    reg spec256_lane_ddr3 = 1'b0;   // the lanes' address is in a DDR3 bank
    wire [63:0] plane_cache_data;
    always @(posedge clock_28)
        spec256_lane_ddr3 <= spec256_slot_ddr3[lanes_address[15:13]];
    assign spec256_lane_read = spec256_rom_font_hit ? spec256_rom_font_q :
                               spec256_lane_ddr3 ? plane_cache_data : spec256_plane_read;

    // The mirror holds the planes of the three banks a 48K game has, where
    // a 48K machine pages them: bank 5 at 0x4000, bank 2 at 0x8000, bank 0
    // at 0xC000 (the loader sends no others). A 128K game pages through the
    // MMU, so each 8K slot's page says which copy a lane's access uses, if
    // any: a slot holding another bank has no planes, and the lanes read
    // the master's byte there and write nothing (plane_present); a slot
    // without planes keeps its own address, so the mirror still drops lane
    // writes below 0x4000. Built from
    // the MMU a cycle late; paging is an OUT, never the access straight
    // after it.
    integer slot;
    always @(posedge clock_28)
        for (slot = 0; slot < 8; slot = slot + 1) begin
            spec256_slot_high[3*slot +: 3] <=
                s256_mmu[8*slot+1 +: 7] == 7'd5 ? {2'd1, s256_mmu[8*slot]} :
                s256_mmu[8*slot+1 +: 7] == 7'd2 ? {2'd2, s256_mmu[8*slot]} :
                s256_mmu[8*slot+1 +: 7] == 7'd0 ? {2'd3, s256_mmu[8*slot]} : slot[2:0];
            spec256_slot_present[slot] <= s256_mmu[8*slot+1 +: 7] == 7'd5 ||
                                          s256_mmu[8*slot+1 +: 7] == 7'd2 ||
                                          s256_mmu[8*slot+1 +: 7] == 7'd0;
            spec256_slot_ddr3[slot] <= s256_mmu[8*slot+4 +: 4] == 4'd0 &&
                                       s256_mmu[8*slot+1 +: 3] != 3'd5 &&
                                       s256_mmu[8*slot+1 +: 3] != 3'd2 &&
                                       s256_mmu[8*slot+1 +: 3] != 3'd0 &&
                                       spec256_banks_with_planes[s256_mmu[8*slot+1 +: 3]];
        end

    wire [127:0] lanes_plane_address;
    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : lane_paging
            assign lanes_plane_address[16*lane +: 16] = {
                spec256_slot_high[3*lanes_address[16*lane+13 +: 3] +: 3],
                lanes_address[16*lane +: 13]};
        end
    endgenerate

    // Every lane writes at the master's address, so lane 0's write serves
    // all eight planes. The loader writes only while colour mode is off,
    // when lanes write nothing.
    // Banks 1, 3, 4, 6 and 7 have their planes in DDR3 behind
    // nexttang_spec256_plane_cache: the loader's words for 0xC000 up after
    // P with such a bank, and the lanes' accesses in a slot holding one
    // (spec256_slot_ddr3), go there rather than to the mirror. A lane read
    // there waits for the cache through the core's WAIT, which holds the
    // master and so every lane with it. Address: bank * 0x4000 + offset,
    // that is the slot's page and the low 13 bits.
    wire loader_bank_ddr3 = spec256_plane_bank != 3'd5 && spec256_plane_bank != 3'd2 &&
                            spec256_plane_bank != 3'd0;
    wire loader_ddr3_write = loader_plane_write && loader_plane_address[15:14] == 2'b11 &&
                             loader_bank_ddr3;
    wire lanes_write_ddr3 = spec256_slot_ddr3[lanes_address[15:13]];

    assign spec256_lane_address = loader_plane_write ? {8{loader_plane_address}} : lanes_plane_address;
    assign spec256_lane_write = (loader_plane_write && !loader_ddr3_write) ||
                                (lanes_write[0] && !lanes_write_ddr3);
    assign spec256_lane_write_data = loader_plane_write ? loader_plane_data : lanes_write_data;

    // A lane write is taken from its last cycle, like the rules' (below).
    reg        lane_writing = 1'b0;
    reg [16:0] lane_write_bank_address = 17'd0;
    reg [63:0] lane_write_word = 64'd0;
    always @(posedge clock_28) begin
        lane_writing <= lanes_write[0] && lanes_write_ddr3;
        if (lanes_write[0] && lanes_write_ddr3) begin
            lane_write_bank_address <= {s256_mmu[8*lanes_address[15:13] +: 4], lanes_address[12:0]};
            lane_write_word <= lanes_write_data;
        end
    end
    wire lane_write_done = lane_writing && !(lanes_write[0] && lanes_write_ddr3);

    // A read by the CPUs in such a slot (not an opcode fetch: the lanes take
    // opcodes and operands from the master), from the master's bus.
    reg        plane_lookup = 1'b0;
    reg [16:0] plane_lookup_address = 17'd0;
    always @(posedge clock_28) begin
        plane_lookup <= spec256_graphics && !s256_mreq_n && !s256_rd_n && s256_m1_n &&
                        spec256_slot_ddr3[s256_a[15:13]];
        plane_lookup_address <= {s256_mmu[8*s256_a[15:13] +: 4], s256_a[12:0]};
    end
    wire plane_wait;
    wire plane_lost;

    // Colour mode from the first instruction fetched at the armed address.
    // A game that resumes in the ROM (a PAUSE loop, the interrupt routine at
    // 0x0038) arms only once a RETN has followed G: NextZXOS runs code at
    // those addresses while it loads the snapshot, and colour mode started
    // there copies every byte the load writes into the planes; it starts
    // the snapshot with a RETN from its NMI handler.
    reg spec256_armed = 1'b0;
    reg spec256_retn_seen = 1'b0;
    // Bit 6: this core takes the loader's E, M and P (BGX1 rules, more
    // backgrounds, planes for other 128K banks); a .SPEC256 that finds it
    // clear leaves them out.
    assign spec256_nr_status = {spec256_cpu_owned, 1'b1, spec256_background_present,
                                spec256_desync, spec256_graphics, spec256_armed,
                                spec256_payload, spec256_mode};
    reg s256_previous_m1_n = 1'b1;

    always @(posedge clock_28) begin
        s256_previous_m1_n <= s256_m1_n;
        if (!s256_cpu_reset_n || loader_disarm || !spec256_mode) begin
            spec256_armed <= 1'b0;
            spec256_graphics <= 1'b0;
        end else if (loader_arm) begin
            spec256_armed <= 1'b1;
            spec256_retn_seen <= 1'b0;
        end else if (spec256_armed && s256_previous_m1_n && !s256_m1_n &&
                     s256_boundary && s256_a == loader_arm_pc &&
                     (loader_arm_pc[15:14] != 2'b00 || spec256_retn_seen)) begin
            spec256_armed <= 1'b0;
            spec256_graphics <= 1'b1;
        end else if (s256_retn) begin
            spec256_retn_seen <= 1'b1;
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

    // A 16 KiB line cache answers most CPU and DMA reads in two cycles
    // instead of the 16 to 26 a DDR3 read takes.
    nexttang_zxnext_memory_port #(
        .CACHE(1)
    ) main_memory (
        .machine_clock(clock_28),
        .machine_reset(machine_reset),
        .memory_available(memory_available),
        .core_request(memory_request),
        .core_read_n(memory_read_n),
        .core_address(memory_address),
        .core_write_data(memory_write_data),
        .core_read_data(memory_read_data),
        .core_wait(memory_wait),
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

    // The core waits for main memory, and for a DDR3 plane the lanes read.
    assign cpu_wait = port_a_wait || plane_wait;

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

    // Spec256's backgrounds (nexttang_spec256_background_store) share the
    // frame store's turn: a second arbiter between the two takes the place
    // of one client, so the CPU's path to the controller is unchanged.
    wire background_controller_request;
    wire background_controller_command_ready;
    wire [2:0] background_controller_command;
    wire background_controller_command_enable;
    wire [28:0] background_controller_address;
    wire background_controller_write_data_ready;
    wire [255:0] background_controller_write_data;
    wire background_controller_write_data_enable;
    wire background_controller_write_data_end;
    wire [31:0] background_controller_write_data_mask;
    wire background_controller_read_data_valid;
    wire background_controller_burst;
    wire shared_controller_request = video_controller_request || background_controller_request;
    wire shared_controller_command_ready;
    wire [2:0] shared_controller_command;
    wire shared_controller_command_enable;
    wire [28:0] shared_controller_address;
    wire shared_controller_write_data_ready;
    wire [255:0] shared_controller_write_data;
    wire shared_controller_write_data_enable;
    wire shared_controller_write_data_end;
    wire [31:0] shared_controller_write_data_mask;
    wire shared_controller_read_data_valid;
    wire shared_controller_burst;

    nexttang_ddr3_ui_arbiter video_arbiter (
        .clock(controller_clock),
        .reset(!controller_reset_n),
        .a_request(video_controller_request),
        .a_command_ready(video_controller_command_ready),
        .a_command(video_controller_command),
        .a_command_enable(video_controller_command_enable),
        .a_address(video_controller_address),
        .a_write_data_ready(video_controller_write_data_ready),
        .a_write_data(video_controller_write_data),
        .a_write_data_enable(video_controller_write_data_enable),
        .a_write_data_end(video_controller_write_data_end),
        .a_write_data_mask(video_controller_write_data_mask),
        .a_read_data_valid(video_controller_read_data_valid),
        .a_burst(video_controller_burst),
        .b_request(background_controller_request),
        .b_command_ready(background_controller_command_ready),
        .b_command(background_controller_command),
        .b_command_enable(background_controller_command_enable),
        .b_address(background_controller_address),
        .b_write_data_ready(background_controller_write_data_ready),
        .b_write_data(background_controller_write_data),
        .b_write_data_enable(background_controller_write_data_enable),
        .b_write_data_end(background_controller_write_data_end),
        .b_write_data_mask(background_controller_write_data_mask),
        .b_read_data_valid(background_controller_read_data_valid),
        .b_burst(background_controller_burst),
        .controller_command_ready(shared_controller_command_ready),
        .controller_command(shared_controller_command),
        .controller_command_enable(shared_controller_command_enable),
        .controller_address(shared_controller_address),
        .controller_write_data_ready(shared_controller_write_data_ready),
        .controller_write_data(shared_controller_write_data),
        .controller_write_data_enable(shared_controller_write_data_enable),
        .controller_write_data_end(shared_controller_write_data_end),
        .controller_write_data_mask(shared_controller_write_data_mask),
        .controller_read_data_valid(shared_controller_read_data_valid),
        .controller_burst(shared_controller_burst)
    );

    // Spec256 backgrounds: the loader's images go to DDR3 (image 0 also
    // straight into the overlay's memory, which shows it first), and the
    // BGX1 rules pick which one the overlay's memory holds. A new pick is
    // copied in from DDR3 during the border after the picture (ULA line
    // 192), about 2 ms, before the next picture starts.
    reg [1:0] background_frame_sync = 2'b00;
    reg       background_frame_7 = 1'b0;
    reg       background_frame_d = 1'b0;
    always @(posedge clock_7)
        background_frame_7 <= s256_ula_vc == 9'd192;
    always @(posedge clock_28) begin
        background_frame_sync <= {background_frame_sync[0], background_frame_7};
        background_frame_d <= background_frame_sync[1];
    end
    wire background_frame = background_frame_sync[1] && !background_frame_d;

    // The game's RAM writes, as bank * 0x4000 + offset: the slot's MMU page,
    // pages 0 to 15 being banks 0 to 7; other pages (the ROM's 0xFF, the
    // Next's own RAM) are not a 128K machine's. Taken from the last cycle
    // of the write, when its address and data are certain.
    reg        s256_writing = 1'b0;
    reg [15:0] s256_write_a = 16'd0;
    reg [7:0]  s256_write_page = 8'hff;
    reg [7:0]  s256_write_value = 8'd0;
    wire       s256_write_now = !s256_mreq_n && !s256_wr_n;
    always @(posedge clock_28) begin
        s256_writing <= s256_write_now;
        if (s256_write_now) begin
            s256_write_a <= s256_a;
            s256_write_page <= s256_mmu[8*s256_a[15:13] +: 8];
            s256_write_value <= s256_bank5_data;
        end
    end
    wire background_rule_write = s256_writing && !s256_write_now && s256_write_page < 8'd16;

    wire [2:0] background_selected;
    wire       background_rules_valid;
    nexttang_spec256_background_rules background_rules (
        .clock(clock_28),
        .reset(!machine_locked),
        .clear(spec256_bgx_clear),
        .load_write(spec256_bgx_write),
        .load_index(spec256_bgx_index),
        .load_data(spec256_bgx_data),
        .running(spec256_graphics),
        .frame(background_frame),
        .write(background_rule_write),
        .write_address({s256_write_page[3:0], s256_write_a[12:0]}),
        .write_data(s256_write_value),
        .valid(background_rules_valid),
        .selected(background_selected)
    );

    wire        background_copy_busy;
    wire        background_copy_write;
    wire [15:0] background_copy_address;
    wire [7:0]  background_copy_data;
    wire        background_lost;
    reg  [2:0]  background_displayed = 3'd0;   // the image in the overlay's memory
    wire        background_wanted = background_selected < 3'd4 &&
                                    spec256_backgrounds_present[background_selected[1:0]];
    wire        background_copy_start = spec256_graphics && background_wanted &&
                                        background_selected != background_displayed &&
                                        !background_copy_busy;
    wire        loader_background_0 = spec256_background_write && spec256_background_image == 2'd0;
    always @(posedge clock_28)
        if (loader_background_0)
            background_displayed <= 3'd0;
        else if (background_copy_start)
            background_displayed <= background_selected;

    assign overlay_background_write = loader_background_0 || background_copy_write;
    assign overlay_background_address = loader_background_0 ? spec256_background_address
                                                            : background_copy_address;
    assign overlay_background_index = loader_background_0 ? spec256_background_index
                                                          : background_copy_data;
    assign overlay_background_shown = background_wanted &&
                                      background_displayed == background_selected;

    nexttang_spec256_background_store #(
        .BASE_BEAT('h20000)
    ) background_store (
        .clock(clock_28),
        .reset(!machine_locked),
        .load_write(spec256_background_write),
        .load_image(spec256_background_image),
        .load_address(spec256_background_address),
        .load_data(spec256_background_index),
        .lost(background_lost),
        .copy_start(background_copy_start),
        .copy_image(background_selected[1:0]),
        .copy_busy(background_copy_busy),
        .copy_write(background_copy_write),
        .copy_address(background_copy_address),
        .copy_data(background_copy_data),
        .memory_clock(controller_clock),
        .memory_reset(!controller_reset_n),
        .controller_request(bgstore_controller_request),
        .controller_command_ready(bgstore_controller_command_ready),
        .controller_command(bgstore_controller_command),
        .controller_command_enable(bgstore_controller_command_enable),
        .controller_address(bgstore_controller_address),
        .controller_write_data_ready(bgstore_controller_write_data_ready),
        .controller_write_data(bgstore_controller_write_data),
        .controller_write_data_enable(bgstore_controller_write_data_enable),
        .controller_write_data_end(bgstore_controller_write_data_end),
        .controller_write_data_mask(bgstore_controller_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(bgstore_controller_read_data_valid),
        .controller_burst(bgstore_controller_burst)
    );


    // The backgrounds and the DDR3 planes take turns as the frame store's
    // partner (above).
    wire bgstore_controller_request;
    wire bgstore_controller_command_ready;
    wire [2:0] bgstore_controller_command;
    wire bgstore_controller_command_enable;
    wire [28:0] bgstore_controller_address;
    wire bgstore_controller_write_data_ready;
    wire [255:0] bgstore_controller_write_data;
    wire bgstore_controller_write_data_enable;
    wire bgstore_controller_write_data_end;
    wire [31:0] bgstore_controller_write_data_mask;
    wire bgstore_controller_read_data_valid;
    wire bgstore_controller_burst;
    wire planes_controller_request;
    wire planes_controller_command_ready;
    wire [2:0] planes_controller_command;
    wire planes_controller_command_enable;
    wire [28:0] planes_controller_address;
    wire planes_controller_write_data_ready;
    wire [255:0] planes_controller_write_data;
    wire planes_controller_write_data_enable;
    wire planes_controller_write_data_end;
    wire [31:0] planes_controller_write_data_mask;
    wire planes_controller_read_data_valid;
    wire planes_controller_burst;

    nexttang_ddr3_ui_arbiter spec256_arbiter (
        .clock(controller_clock),
        .reset(!controller_reset_n),
        .a_request(bgstore_controller_request),
        .a_command_ready(bgstore_controller_command_ready),
        .a_command(bgstore_controller_command),
        .a_command_enable(bgstore_controller_command_enable),
        .a_address(bgstore_controller_address),
        .a_write_data_ready(bgstore_controller_write_data_ready),
        .a_write_data(bgstore_controller_write_data),
        .a_write_data_enable(bgstore_controller_write_data_enable),
        .a_write_data_end(bgstore_controller_write_data_end),
        .a_write_data_mask(bgstore_controller_write_data_mask),
        .a_read_data_valid(bgstore_controller_read_data_valid),
        .a_burst(bgstore_controller_burst),
        .b_request(planes_controller_request),
        .b_command_ready(planes_controller_command_ready),
        .b_command(planes_controller_command),
        .b_command_enable(planes_controller_command_enable),
        .b_address(planes_controller_address),
        .b_write_data_ready(planes_controller_write_data_ready),
        .b_write_data(planes_controller_write_data),
        .b_write_data_enable(planes_controller_write_data_enable),
        .b_write_data_end(planes_controller_write_data_end),
        .b_write_data_mask(planes_controller_write_data_mask),
        .b_read_data_valid(planes_controller_read_data_valid),
        .b_burst(planes_controller_burst),
        .controller_command_ready(background_controller_command_ready),
        .controller_command(background_controller_command),
        .controller_command_enable(background_controller_command_enable),
        .controller_address(background_controller_address),
        .controller_write_data_ready(background_controller_write_data_ready),
        .controller_write_data(background_controller_write_data),
        .controller_write_data_enable(background_controller_write_data_enable),
        .controller_write_data_end(background_controller_write_data_end),
        .controller_write_data_mask(background_controller_write_data_mask),
        .controller_read_data_valid(background_controller_read_data_valid),
        .controller_burst(background_controller_burst)
    );
    assign background_controller_request = bgstore_controller_request || planes_controller_request;

    nexttang_spec256_plane_cache #(
        .BASE_BEAT('h30000)
    ) plane_cache (
        .clock(clock_28),
        .reset(!machine_locked),
        .invalidate(loader_disarm),
        .lookup(plane_lookup),
        .address(plane_lookup_address),
        .read_data(plane_cache_data),
        .wait_request(plane_wait),
        .write(loader_ddr3_write || lane_write_done),
        .write_address(loader_ddr3_write ? {spec256_plane_bank, loader_plane_address[13:0]}
                                         : lane_write_bank_address),
        .write_data(loader_ddr3_write ? loader_plane_data : lane_write_word),
        .lost(plane_lost),
        .memory_clock(controller_clock),
        .memory_reset(!controller_reset_n),
        .controller_request(planes_controller_request),
        .controller_command_ready(planes_controller_command_ready),
        .controller_command(planes_controller_command),
        .controller_command_enable(planes_controller_command_enable),
        .controller_address(planes_controller_address),
        .controller_write_data_ready(planes_controller_write_data_ready),
        .controller_write_data(planes_controller_write_data),
        .controller_write_data_enable(planes_controller_write_data_enable),
        .controller_write_data_end(planes_controller_write_data_end),
        .controller_write_data_mask(planes_controller_write_data_mask),
        .controller_burst(planes_controller_burst),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(planes_controller_read_data_valid)
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
        .b_request(shared_controller_request),
        .b_command_ready(shared_controller_command_ready),
        .b_command(shared_controller_command),
        .b_command_enable(shared_controller_command_enable),
        .b_address(shared_controller_address),
        .b_write_data_ready(shared_controller_write_data_ready),
        .b_write_data(shared_controller_write_data),
        .b_write_data_enable(shared_controller_write_data_enable),
        .b_write_data_end(shared_controller_write_data_end),
        .b_write_data_mask(shared_controller_write_data_mask),
        .b_read_data_valid(shared_controller_read_data_valid),
        .b_burst(shared_controller_burst),
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
    assign memory_wait = 1'b0;
    assign layer2_data = 8'h00;
    // No port C without DDR3 (CORE_OPTION leaves its commands out).
    assign ram_c_ack = 1'b0;
    assign ram_c_read_data = 8'h00;
    assign ram_c_busy = 1'b0;

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
    wire overlay_frame_start;
    wire overlay_pixel_valid;
    wire [8:0] overlay_x;
    wire [8:0] overlay_y;
    wire [8:0] overlay_pixel;

    // The paper's first line in the captured picture: the capture line on
    // which the ULA's line counter reads 0, sampled mid-paper (x 180), where
    // the pixel pipeline's few cycles of delay keep the ULA on the same line.
    reg [8:0] spec256_paper_top = 9'd48;
    // The planes are bank 5's; a 128K game showing the shadow screen (bank
    // 7) is shown as the core draws it.
    reg [1:0] spec256_shadow_sync = 2'b00;
    always @(posedge clock_28)
        spec256_shadow_sync <= {spec256_shadow_sync[0], s256_ula_shadow};
    wire spec256_shadow = spec256_shadow_sync[1];
    always @(posedge clock_7)
        if (capture_pixel_valid && capture_x == 9'd180 && s256_ula_vc == 9'd0)
            spec256_paper_top <= capture_y;

    // The paper's first pixel in the captured picture likewise: the capture
    // pixel at which the ULA's pixel counter reads 0, on a paper line, plus
    // the pixel pipeline's delay, 18 (measured on the Console 138K at 60 Hz:
    // Highway Encounter's text lines up), plus a trim (the loader's X). The
    // edge moves with the 50/60 Hz timing too: with 52 fixed, EmuZWin games,
    // whose index 0xFF shows the core's own pixel, drew text with the core's
    // pixels 4 to one side of the planes'.
    localparam [8:0] SPEC256_PAPER_DELAY = 9'd18;
    reg [8:0] spec256_paper_left = 9'd52;
    always @(posedge clock_7)
        if (capture_pixel_valid && s256_ula_vc == 9'd96 && s256_ula_hc == 9'd0)
            spec256_paper_left <= capture_x + SPEC256_PAPER_DELAY +
                                  {spec256_paper_trim[7], spec256_paper_trim};

    nexttang_spec256_overlay spec256_overlay (
        .clock_7(clock_7),
        .clock_28(clock_28),
        .reset(!machine_locked),
        .enable(spec256_graphics && !spec256_shadow),
        .paper_top(spec256_paper_top),
        .paper_left(spec256_paper_left),
        .capture_frame_start(capture_frame_start),
        .capture_pixel_valid(capture_pixel_valid),
        .capture_x(capture_x),
        .capture_y(capture_y),
        .capture_pixel(capture_pixel),
        .frame_start(overlay_frame_start),
        .pixel_valid(overlay_pixel_valid),
        .x(overlay_x),
        .y(overlay_y),
        .pixel(overlay_pixel),
        .plane_address(spec256_overlay_address),
        .plane_data(spec256_overlay_data),
        .palette_write(spec256_palette_write),
        .palette_index(spec256_palette_index),
        .palette_rgb(spec256_palette_rgb),
        .render_dos(spec256_rules_flags[0]),
        .zxpoly_mode(spec256_zxpoly_mode),
        .bk_over_ff(spec256_cfg[3]),
        .cfg(spec256_cfg),
        .background_present(overlay_background_shown),
        .background_write(overlay_background_write),
        .background_address(overlay_background_address),
        .background_index(overlay_background_index),
        .bank5_write(s256_bank5_write),
        .bank5_address(s256_bank5_address),
        .bank5_data(s256_bank5_data)
    );
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
        .source_frame_start(overlay_frame_start),
        .source_short(capture_60_sync[1]),
        .source_pixel_valid(overlay_pixel_valid),
        .source_x(overlay_x),
        .source_y(overlay_y),
        .source_pixel(overlay_pixel),
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
    // the card is selected, and counted. (Its sum, once reported beside the
    // count, made way for the USB diagnostics.)
    reg [23:0] sd_byte_count = 24'd0;
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
            if (sd_bit_count == 3'd7 && {sd_shift[6:0], sd_miso_previous} != 8'hff)
                sd_byte_count <= sd_byte_count + 24'd1;
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

    // The live wait and contention lines, registered: a status sample a
    // cycle old is as good, and unregistered they joined the CPU's decoder to
    // the status message in one path.
    reg cpu_wait_sampled = 1'b0, cpu_contend_sampled = 1'b0;

    always @(posedge clock_28) begin
        cpu_wait_sampled <= cpu_wait;
        cpu_contend_sampled <= cpu_contend;
    end

    // The USB diagnostics cross from the USB clock on two flops; a count
    // caught mid-change reads one off, which is harmless in a report.
    reg [31:0] usb_diagnostics_meta = 32'd0, usb_diagnostics_7 = 32'd0;
    reg [63:0] usb_debug_meta = 64'd0, usb_debug_7 = 64'd0;
    always @(posedge clock_7) begin
        usb_diagnostics_meta <= usb_diagnostics;
        usb_diagnostics_7 <= usb_diagnostics_meta;
        usb_debug_meta <= usb_debug_word;
        usb_debug_7 <= usb_debug_meta;
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
            spec256_mode, spec256_graphics, spec256_desync, 5'b0, wait_cycles_reported,
            usb_debug_7[63:32],
            usb_diagnostics_7,
            usb_debug_7[31:0]
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
    wire uart_byte_valid;
    // While the Spec256 loader takes raw plane or palette bytes from the
    // UART, no other command may see them.
    wire command_valid = uart_byte_valid && !(spec256_payload && !spec256_cpu_owned);

    nexttang_uart_receiver #(
        .CLOCK_HZ(28000000),
        .BAUD_RATE(115200)
    ) command_receiver (
        .clock(clock_28),
        .reset(!machine_locked),
        .receive(debug_uart_rx),
        .data(command_byte),
        .data_valid(uart_byte_valid)
    );

    // The official Pi debug protocol over this UART: X, a length and that many
    // bytes go to the core's Pi debug slave as one SPI command, through the
    // FPGA's own SPI master, and its reply comes back framed. While a frame is
    // arriving its bytes are kept from the single-letter commands below; while
    // a debug session is open the reply owns the transmit line.
    wire       pi_frame_active;
    wire       pi_session;
    wire       pi_link_tx;
    wire       pi_select;
    wire       pi_byte_valid;
    wire [7:0] pi_byte;
    wire       pi_byte_ready;
    wire       pi_reply_done;
    wire [7:0] pi_reply;
    wire       pi_spi_idle;
    wire       board_command_valid = command_valid && !pi_frame_active;
    wire       bp_strobe;
    wire [7:0] bp_slot;
    wire       bp_enable;
    wire [15:0] bp_address;
    wire       bp_paged;
    wire [7:0] bp_page;
    wire       bp_hit;

    nexttang_pi_debug_uart_link #(
        .CLOCK_HZ(28000000),
        .BAUD_RATE(115200)
    ) pi_debug_link (
        .clock(clock_28),
        .reset(!machine_locked),
        .rx_valid(command_valid),
        .rx_byte(command_byte),
        .frame_active(pi_frame_active),
        .session_active(pi_session),
        .tx(pi_link_tx),
        .spi_select(pi_select),
        .spi_valid(pi_byte_valid),
        .spi_byte(pi_byte),
        .spi_ready(pi_byte_ready),
        .spi_done(pi_reply_done),
        .spi_reply(pi_reply),
        .spi_idle(pi_spi_idle),
        .bp_strobe(bp_strobe),
        .bp_slot(bp_slot),
        .bp_enable(bp_enable),
        .bp_address(bp_address),
        .bp_paged(bp_paged),
        .bp_page(bp_page),
        .inject_pause(bp_hit)
    );

    nexttang_breakpoints #(
        .SLOTS(10)
    ) breakpoints (
        .clock(clock_28),
        .reset(!machine_locked),
        .write_strobe(bp_strobe),
        .write_slot(bp_slot),
        .write_enable(bp_enable),
        .write_address(bp_address),
        .write_paged(bp_paged),
        .write_page(bp_page),
        .mmu(core_mmu),
        .next_pc(cpu_next_pc),
        .cpu_stopped(cpu_stopped),
        .break_now(cpu_break),
        .hit(bp_hit)
    );

    nexttang_pi_spi_master pi_debug_spi (
        .clock(clock_28),
        .reset(!machine_locked),
        .select_in(pi_select),
        .byte_valid(pi_byte_valid),
        .byte_in(pi_byte),
        .byte_ready(pi_byte_ready),
        .done(pi_reply_done),
        .byte_out(pi_reply),
        .idle(pi_spi_idle),
        .memory_busy(ram_c_request || ram_c_busy),
        .spi_ce_n(pi_spi_ce_n),
        .spi_sclk(pi_spi_sclk),
        .spi_mosi(pi_spi_mosi),
        .spi_miso(core_gpio[9])
    );
    // The Spec256 loader takes its command language from the debug UART or,
    // once the CPU claims it, from NextREG writes, so a NextZXOS dot command
    // can load a game's colour without a host:
    //   NextREG 0x3E  write: one loader byte; read: SPEC256_NR_ID (0xA1:
    //                 marker A, interface version 1)
    //   NextREG 0x3F  write: bit 0 the CPU owns the loader (UART loader bytes
    //                 are then ignored; other UART commands still act), bit 7
    //                 abort (the parser waits for a command again);
    //                 read: bit 0 planes mode (S1), 1 inside a raw payload,
    //                 2 armed, 3 colour running, 4 desync, 5 background
    //                 present, 6 E/M/P understood (always 1 here), 7 the
    //                 CPU owns the loader
    // A NextREG write reaches o_DEBUG_NR_* once, in the cycle the core takes
    // it, so each one is one loader byte.
    wire spec256_nr_byte = core_nr_write && core_nr_register == 8'h3E;
    always @(posedge clock_28) begin
        spec256_abort <= 1'b0;
        if (!machine_locked) begin
            spec256_cpu_owned <= 1'b0;
        end else if (core_nr_write && core_nr_register == 8'h3F) begin
            spec256_cpu_owned <= core_nr_data[0];
            spec256_abort <= core_nr_data[7];
        end
    end

`ifdef NEXTTANG_ZXNEXT_DDR3
    nexttang_spec256_uart_loader spec256_loader (
        .clock(clock_28),
        .reset(!machine_locked),
        .byte_in(spec256_cpu_owned ? core_nr_data : command_byte),
        .byte_valid(spec256_cpu_owned ? spec256_nr_byte : uart_byte_valid),
        .abort(spec256_abort),
        .payload(spec256_payload),
        .spec256_mode(spec256_mode),
        .plane_write(loader_plane_write),
        .plane_address(loader_plane_address),
        .plane_data(loader_plane_data),
        .palette_write(spec256_palette_write),
        .palette_index(spec256_palette_index),
        .palette_rgb(spec256_palette_rgb),
        .arm(loader_arm),
        .arm_pc(loader_arm_pc),
        .disarm(loader_disarm),
        .rules_flags(spec256_rules_flags),
        .background_write(spec256_background_write),
        .background_image(spec256_background_image),
        .background_address(spec256_background_address),
        .background_index(spec256_background_index),
        .background_present(spec256_background_present),
        .backgrounds_present(spec256_backgrounds_present),
        .bgx_clear(spec256_bgx_clear),
        .bgx_write(spec256_bgx_write),
        .bgx_index(spec256_bgx_index),
        .bgx_data(spec256_bgx_data),
        .cfg(spec256_cfg),
        .rules(spec256_rules),
        .zxpoly_mode(spec256_zxpoly_mode),
        .paper_trim(spec256_paper_trim),
        .plane_bank(spec256_plane_bank),
        .banks_with_planes(spec256_banks_with_planes)
    );
`else
    assign spec256_payload = 1'b0;
    assign spec256_mode = 1'b0;
    assign spec256_desync = 1'b0;
    assign spec256_rules_flags = 8'd0;
    assign spec256_background_present = 1'b0;
    assign spec256_background_write = 1'b0;
    assign spec256_background_address = 16'd0;
    assign spec256_background_index = 8'd0;
    assign spec256_background_image = 2'd0;
    assign spec256_backgrounds_present = 4'd0;
    assign spec256_bgx_clear = 1'b0;
    assign spec256_bgx_write = 1'b0;
    assign spec256_bgx_index = 10'd0;
    assign spec256_bgx_data = 8'd0;
    assign spec256_cfg = 24'd0;
    assign spec256_rules = 512'd0;
    assign spec256_zxpoly_mode = 3'd0;
    assign spec256_paper_trim = 8'd0;
    assign spec256_plane_bank = 3'd0;
    assign spec256_banks_with_planes = 8'd0;
    assign spec256_nr_status = 8'd0;
`endif

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
    // N followed by two hex digits holds the Kempston joystick (bit 0 right,
    // 1 left, 2 down, 3 up, 4 fire) until the next N. Digits are lower case,
    // as for K and J: upper-case B, C and E are Spectrum loader commands.
    reg [1:0]  joystick_digits_left = 2'd0;
    reg [3:0]  joystick_command_high = 4'd0;

    always @(posedge clock_28) begin
        if (board_command_valid) begin
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

            if (command_byte == "N") begin
                joystick_digits_left <= 2'd2;
            end else if (joystick_digits_left != 2'd0 && command_is_digit) begin
                joystick_command_high <= command_digit;
                joystick_digits_left <= joystick_digits_left - 2'd1;
`ifdef NEXTTANG_ZXNEXT_IO
                if (joystick_digits_left == 2'd1)
                    host_kempston <= {joystick_command_high[0], command_digit};
`endif
            end else begin
                joystick_digits_left <= 2'd0;
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
        if (board_command_valid) begin
            video_command <= command_byte == "V";
            if (video_command && (command_byte == "0" || command_byte == "1"))
                video_memory_enable <= command_byte[0];
        end
    end
`endif

    always @(posedge clock_28) begin
        trigger_command_done <= 1'b0;
        if (board_command_valid) begin
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
        .freeze_request(board_command_valid && command_byte == "F"),
        .rearm_request(board_command_valid && command_byte == "R"),
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
        .dump_request(board_command_valid && command_byte == "D"),
        .sending(capture_sending),
        .transmit(capture_transmit)
    );

    assign debug_uart_tx = pi_session ? pi_link_tx
                         : capture_sending ? capture_transmit
                         : trace_frozen ? trace_transmit
                         : log_sending ? log_transmit
                         : status_transmit;
endmodule

`default_nettype wire
