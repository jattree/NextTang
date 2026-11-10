// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// The ZX Spectrum Next machine every NextTang board shares.
//
// This module holds everything that does not depend on the board: the
// official core (rtl/zxnext.vhd), the CPU clock enables, the core's own reset
// requests, the debug UART with the Pi debug protocol, its FPGA-side SPI
// master and the hardware breakpoints, and the status, trace and log taps that
// report over that UART. It has no pins, no PLLs and no vendor primitives.
//
// A board shell supplies the machine clock tree, main memory behind ports A,
// B and C, video out, audio out, keyboard and joystick input and the SD
// socket, and connects them here. The contracts below are what a shell must
// keep. They describe what the core already does; nothing in zxnext.vhd
// changes for them.
//
// ---------------------------------------------------------------- clocks
//
// clock_28, clock_28_n, clock_14 and clock_7 are the related machine clocks
// (clock_28_n the inverse of clock_28; 14 and 7 MHz rising with it), and
// psg_enable the sound chips' enable, all from the board's clock tree.
// machine_reset holds the machine in reset; machine_locked is low until the
// clock tree has locked and resets the taps and the debug link. A board whose
// main memory needs calibration keeps machine_reset high until it is ready.
//
// The CPU runs on clock_28 with rising and falling enables made here
// (nexttang_zxnext_cpu_enables) at the speed the core selects.
//
// ---------------------------------------------------------- memory contract
//
// All three ports address the core's 2 MiB SRAM space: ram_x_address[20:0]
// is the byte address, SRAM unit (16 KiB) = address[20:14] = RAM bank + 16.
// Everything is in the clock_28 domain.
//
// Port A: CPU and DMA, read and write. May stall.
//   ram_a_cycle_request (o_RAM_A_REQ2, from MiSTer) is a level, high for the
//   whole of a memory cycle that reaches main memory. ram_a_request
//   (o_RAM_A_REQ) is the one-cycle pulse at its start. ram_a_read_n is 0 for
//   a read, 1 for a write; ram_a_write_data is the byte written.
//   ram_a_address_21 is the Issue 5 4 MiB bit; it is 0 on these boards
//   (g_board_issue 2).
//   cpu_wait (i_CPU_WAIT, active high) holds the CPU. The board raises it
//   combinationally from the request, so it is already high when the Z80
//   samples WAIT in T2, and lowers it when ram_a_read_data is valid (a read)
//   or the write has been accepted. A board that never stalls ties it low and
//   answers a read one clock_28 cycle after the request, as the official
//   board's SRAM does (with the core's own 28 MHz read wait state).
//   rtl/memory/nexttang_zxnext_memory_port.v implements this for a slow
//   memory behind a line cache.
//
// Port B: Layer 2, read only. Cannot stall.
//   layer2_request_toggle (o_RAM_B_REQ_T) toggles for each read of
//   layer2_address. The core samples layer2_data unconditionally four
//   clock_28 cycles (142.9 ns) after the toggle; a late byte is a wrong
//   pixel, and two toggles before the board takes the first lose a read.
//   A board that serves Layer 2 from a mirror may instead answer
//   layer2_address combinationally or one cycle later and ignore the toggle.
//   layer2_prefetch_toggle and layer2_prefetch_address announce each of those
//   reads a fixed number of pixels earlier (eight; the core's lookahead copy of
//   its Layer 2 address path), in the same order, so a board whose memory
//   cannot meet the four-cycle deadline can fetch ahead. A setting changed
//   within that distance can make an announcement wrong; compare addresses.
//   LAYER2_UNITS has bit u set for each SRAM unit u the board can serve on
//   this port; the core shows Layer 2 kept in any other unit as transparent
//   (g_layer2_units). A board that serves none sets it to zero.
//
// Port C: the official Pi debug slave's main-memory commands
//   (CMD_SRAM_R/W, CORE_OPTION bits 8 and 13). Background.
//   ram_c_request is held until the board answers with ram_c_ack, a one-cycle
//   pulse; read data is valid in ram_c_read_data from the cycle after it.
//   Any latency is allowed, but port C must not starve ports A or B.
//   ram_c_busy tells the FPGA-side SPI master that a port C access is still
//   in progress so it does not clock the next byte too early. A board
//   without port C clears bits 8 and 13 of CORE_OPTION and ties ram_c_ack,
//   ram_c_read_data and ram_c_busy low.
//
// Write snoop: every main-memory write the machine makes leaves on port A or
//   port C. Boards that keep copies of main memory (a Layer 2 mirror, a CPU
//   line cache) update them from those writes, and must merge port C into
//   port A's path ahead of every copy (nexttang_zxnext_port_c_mux) so a
//   debugger write cannot leave a copy stale.
//
// Status: memory_faults[2:0] = {timeout, overrun, calibration lost} from the
//   board's memory service, 0 where it has none, is reported on the status
//   UART.
//
// --------------------------------------------------------- video contract
//
// core_rgb[8:0] (RGB333), core_hsync_n, core_vsync_n, core_blank_n,
// core_video_60 (1 in 60 Hz timing), core_hdmi_pixel (the core's HDMI pixel
// window), core_hdmi_lock (frame lock pulse) and core_hdmi_reset leave the
// core's 14 MHz pipeline. The Console scales them to 720p; a board with the
// official hdmi_frame can output native 576p50/480p60.
//
// Status taps from the board's video path, all in the clock_7 domain:
// capture_frame_start, capture_pixel_valid, capture_x, capture_y and
// capture_pixel describe the frame the board captured (tie low where there
// is none), video_clock_locked the board's video PLL.
//
// --------------------------------------------------------- input contract
//
// keyboard_rows (o_KBD_ROW) select matrix rows; keyboard_columns (i_KBD_COL)
// answer them, active low. function_keys[10:1] are F10 down to F1 for the
// core's hot keys. left_joystick and right_joystick are the core's 12-bit
// joystick words. host_keys and host_functions are keys held from the debug
// UART (K and J commands, below), which the board ORs into its own.
//
// ---------------------------------------------------------- debug contract
//
// debug_uart_rx and debug_uart_tx are the board's debug UART at 115200 baud.
// The Pi debug slave's SPI (GPIO 8 CE0, 9 MISO, 10 MOSI, 11 SCLK) is driven
// here by nexttang_pi_spi_master from that UART, and the slave is opened
// without NextREG 0xA0. Bytes on the UART that the machine does not take are
// passed to the board on board_command_valid / board_command_byte for its own
// commands.
//
// The SD card is on the core's SPI master (spi_clock, spi_mosi,
// spi_sd0_select_n, spi_sd_miso). With SD_MONITOR set, every byte the card
// sends is counted and summed on the status UART.

`default_nettype none

module nexttang_next_machine #(
    parameter [127:0] LAYER2_UNITS = 128'd0,
    parameter [15:0]  CORE_OPTION = 16'hDEF2,
    parameter integer SD_MONITOR = 0,
    // 1: the M1 fetch trace (F/R), the NextREG log and the divMMC capture (D)
    // on the debug UART; seven block RAMs. 0 leaves them out (the Nano 20K,
    // which needs the block RAMs); the status line and the Pi debug link stay.
    parameter integer DEBUG_TAPS = 1,
    // 0: the Pi debug slave's SPI is driven by the FPGA's own master from the
    // debug UART (as above). 1: it is the board's pins pi_ce0_n, pi_sclk,
    // pi_mosi and pi_miso, for a real Raspberry Pi (the Nano 20K's Pi Zero);
    // the UART's Pi protocol is then unused.
    parameter integer PI_SPI_PINS = 0
) (
    // clocks and resets
    input  wire        clock_28,
    input  wire        clock_28_n,
    input  wire        clock_14,
    input  wire        clock_7,
    input  wire        psg_enable,
    input  wire        machine_reset,
    input  wire        machine_locked,

    // memory port A
    output wire [20:0] ram_a_address,
    output wire        ram_a_address_21,
    output wire        ram_a_request,
    output wire        ram_a_cycle_request,
    output wire        ram_a_read_n,
    output wire [7:0]  ram_a_write_data,
    input  wire [7:0]  ram_a_read_data,
    input  wire        cpu_wait,

    // memory port B
    output wire [20:0] layer2_address,
    output wire        layer2_request_toggle,
    output wire [20:0] layer2_prefetch_address,   // o_RAM_B_PF_*: the read a few pixels ahead
    output wire        layer2_prefetch_toggle,
    input  wire [7:0]  layer2_data,

    // memory port C
    output wire [20:0] ram_c_address,
    output wire        ram_c_request,
    output wire        ram_c_read_n,
    output wire [7:0]  ram_c_write_data,
    input  wire [7:0]  ram_c_read_data,
    input  wire        ram_c_ack,
    input  wire        ram_c_busy,
    input  wire [2:0]  memory_faults,

    // video
    output wire [8:0]  core_rgb,
    output wire        core_hsync_n,
    output wire        core_vsync_n,
    output wire        core_blank_n,
    output wire        core_video_60,
    output wire        core_hdmi_pixel,
    output wire        core_hdmi_lock,
    output wire        core_hdmi_reset,
    input  wire        video_clock_locked,
    input  wire        capture_frame_start,
    input  wire        capture_pixel_valid,
    input  wire [8:0]  capture_x,
    input  wire [8:0]  capture_y,
    input  wire [8:0]  capture_pixel,
    input  wire        capture_protocol_error,
    input  wire        frame_store_fault,

    // audio
    output wire [12:0] core_audio_left,
    output wire [12:0] core_audio_right,

    // input
    output wire [7:0]  keyboard_rows,
    input  wire [4:0]  keyboard_columns,
    input  wire [10:1] function_keys,
    input  wire [11:0] left_joystick,
    input  wire [11:0] right_joystick,
    input  wire        keyboard_connected,
    input  wire        input_active,
    output reg  [39:0] host_keys,
    output reg  [10:1] host_functions,

    // SD card on the core's SPI
    output wire        spi_clock,
    output wire        spi_mosi,
    output wire        spi_sd0_select_n,
    input  wire        spi_sd_miso,

    // debug UART
    input  wire        debug_uart_rx,
    output wire        debug_uart_tx,
    output wire        board_command_valid,
    output wire [7:0]  board_command_byte,

    // Pi debug slave on pins (PI_SPI_PINS = 1; ignored otherwise)
    input  wire        pi_ce0_n,
    input  wire        pi_sclk,
    input  wire        pi_mosi,
    output wire        pi_miso
);
    initial begin
        host_keys = 40'b0;
        host_functions = 10'b0;
    end

    wire cpu_rising_enable;
    wire cpu_falling_enable;
    wire cpu_enables_locked;
    wire [1:0] cpu_speed;
    wire cpu_contend;
    wire cpu_clock_lsb;

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

    // The Pi debug slave's SPI: the FPGA's own master below, or (PI_SPI_PINS)
    // a Raspberry Pi on the board's pins, synchronised to clock_28.
    wire        master_spi_ce_n;
    wire        master_spi_sclk;
    wire        master_spi_mosi;
    reg  [1:0]  pin_ce_n_sync = 2'b11, pin_sclk_sync = 2'b00, pin_mosi_sync = 2'b00;
    always @(posedge clock_28) begin
        pin_ce_n_sync <= {pin_ce_n_sync[0], pi_ce0_n};
        pin_sclk_sync <= {pin_sclk_sync[0], pi_sclk};
        pin_mosi_sync <= {pin_mosi_sync[0], pi_mosi};
    end
    wire        pi_spi_ce_n = PI_SPI_PINS != 0 ? pin_ce_n_sync[1] : master_spi_ce_n;
    wire        pi_spi_sclk = PI_SPI_PINS != 0 ? pin_sclk_sync[1] : master_spi_sclk;
    wire        pi_spi_mosi = PI_SPI_PINS != 0 ? pin_mosi_sync[1] : master_spi_mosi;
    wire [27:0] core_gpio;
    // Hardware breakpoints (rtl/debug/nexttang_breakpoints.vhd).
    wire [15:0] cpu_next_pc;
    wire        cpu_stopped;
    wire        cpu_break;
    wire [63:0] core_mmu;

    wire        core_m1_n;
    wire        core_wr_n;
    wire        core_rd_n;
    wire [7:0]  core_bus_data;
    wire        core_nr_write;
    wire [7:0]  core_nr_register;
    wire [7:0]  core_nr_data;
    wire        core_iorq_n;
    wire [15:0] core_bus_address;

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
        .i_JOY_RIGHT(right_joystick),
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
        .o_RGB_BK_n(core_blank_n),
        .o_RGB_HS_n(core_hsync_n),
        .o_VIDEO_50_60(core_video_60),
        .o_VIDEO_SCANLINES(),
        .o_VIDEO_SCANDOUBLE(),
        .o_VIDEO_MODE(core_video_mode),
        .o_MACHINE_TIMING(),
        .o_HDMI_RESET(core_hdmi_reset),
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
        .o_RAM_A_ADDR_21(ram_a_address_21),
        .o_RAM_A_REQ(ram_a_request),
        .o_RAM_A_REQ2(ram_a_cycle_request),
        .o_RAM_A_RD_n(ram_a_read_n),
        .i_RAM_A_DI(ram_a_read_data),
        .o_RAM_A_DO(ram_a_write_data),
        // Active high. The port defaults to '1', which would hold the CPU.
        .i_CPU_WAIT(cpu_wait),

        .o_RAM_B_ADDR(layer2_address),
        .o_RAM_B_REQ_T(layer2_request_toggle),
        .o_RAM_B_PF_ADDR(layer2_prefetch_address),
        .o_RAM_B_PF_REQ_T(layer2_prefetch_toggle),
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
        .o_DEBUG_IORQ_n(core_iorq_n)
    );

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
        lit_pixel_seen, !machine_reset, video_clock_locked
    };
    // Last opcode address, border colour, USB keyboard connected, any key or
    // joystick input held, capture and frame store faults (a dropped frame, or
    // a line late from DDR3), then the memory service's timeout, overrun and
    // calibration loss.
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
    // (it stops if contention or main memory holds the CPU for good).
    reg [15:0] cpu_enable_count = 16'd0;

    always @(posedge clock_28) begin
        if (cpu_rising_enable)
            cpu_enable_count <= cpu_enable_count + 16'd1;
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

    generate
        if (SD_MONITOR != 0) begin : sd_monitor
            reg        sd_clock_previous = 1'b0;
            reg        sd_miso_previous = 1'b1;
            reg [2:0]  sd_bit_count = 3'd0;
            reg [7:0]  sd_shift = 8'd0;

            always @(posedge clock_28) begin
                sd_clock_previous <= spi_clock;
                sd_miso_previous <= spi_sd_miso;
                if (spi_sd0_select_n) begin
                    sd_bit_count <= 3'd0;
                end else if (spi_clock && !sd_clock_previous) begin
                    sd_shift <= {sd_shift[6:0], sd_miso_previous};
                    sd_bit_count <= sd_bit_count + 3'd1;
                    // 0xff is what the card sends while it has nothing to
                    // say, and how many of those come varies, so they are
                    // left out.
                    if (sd_bit_count == 3'd7 && {sd_shift[6:0], sd_miso_previous} != 8'hff) begin
                        sd_byte_count <= sd_byte_count + 24'd1;
                        sd_checksum <= sd_checksum + {24'd0, sd_shift[6:0], sd_miso_previous};
                    end
                end
            end
        end
    endgenerate

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
    assign     board_command_valid = command_valid && !pi_frame_active;
    assign     board_command_byte = command_byte;
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
        .spi_ce_n(master_spi_ce_n),
        .spi_sclk(master_spi_sclk),
        .spi_mosi(master_spi_mosi),
        .spi_miso(core_gpio[9])
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
        if (board_command_valid) begin
            if (command_byte == "K") begin
                key_digits_left <= 4'd10;
            end else if (key_digits_left != 4'd0 && command_is_digit) begin
                key_command_mask <= {key_command_mask[35:0], command_digit};
                key_digits_left <= key_digits_left - 4'd1;
                if (key_digits_left == 4'd1)
                    host_keys <= {key_command_mask[35:0], command_digit};
            end else begin
                key_digits_left <= 4'd0;
            end

            if (command_byte == "J") begin
                function_digits_left <= 2'd3;
            end else if (function_digits_left != 2'd0 && command_is_digit) begin
                function_command_mask <= {function_command_mask[7:0], command_digit};
                function_digits_left <= function_digits_left - 2'd1;
                if (function_digits_left == 2'd1)
                    host_functions <= {function_command_mask[5:0], command_digit};
            end else begin
                function_digits_left <= 2'd0;
            end
        end
    end

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

    wire log_sending;
    wire log_transmit;
    wire capture_sending;
    wire capture_transmit;
    generate
    if (DEBUG_TAPS != 0) begin : debug_taps
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
    end else begin : no_debug_taps
        assign trace_frozen = 1'b0;
        assign trace_transmit = 1'b1;
        assign log_sending = 1'b0;
        assign log_transmit = 1'b1;
        assign capture_sending = 1'b0;
        assign capture_transmit = 1'b1;
    end
    endgenerate

    assign pi_miso = core_gpio[9];

    assign debug_uart_tx = pi_session ? pi_link_tx
                         : capture_sending ? capture_transmit
                         : trace_frozen ? trace_transmit
                         : log_sending ? log_transmit
                         : status_transmit;
endmodule

`default_nettype wire
