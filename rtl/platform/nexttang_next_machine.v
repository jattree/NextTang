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
// joystick words. mouse_x, mouse_y and mouse_wheel are the Kempston mouse's
// counters (X up to the right, Y up the screen, wrapping) and mouse_buttons
// its middle, right and left buttons. host_keys and host_functions are keys
// held from the debug UART (K and J commands, below), which the board ORs
// into its own. The debug UART can also hold the left joystick (Y and three
// hex digits, the core's 12-bit word) and place the mouse (M and five hex
// digits: buttons, X, Y); both add to the board's own.
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
// With RZX bit 0, Z on the debug UART starts an RZX input recording
// (docs/replay-and-rewind.md): at once if the CPU is running, or when it is
// next resumed if it is stopped, so a host can pause the CPU, read the
// starting snapshot through the debugger, send Z and resume. z stops it. From
// the start until the recording is sent the UART carries it
// (rtl/debug/nexttang_rzx_uart.v) instead of status lines or debugger replies.
//
// With RZX bit 1, P on the debug UART while the CPU is stopped arms the RZX
// player (rtl/debug/nexttang_rzx_play_link.v has the byte protocol): the host
// puts the machine at the recording's snapshot through the debugger, sends P
// and the first part of the recording, and resumes. From that resume until
// playing ends, every byte received is the recording, the CPU's port reads
// and maskable interrupt come from it, and the UART's transmit side carries
// the player's progress. With both bits, a recording the host ends with FE 02
// hands over to the recorder as playing ends and stops the CPU there: the
// recording carries on from the frame the replay reached (a rewind).
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
    // 1: the status line every quarter second on the debug UART (flags, PC,
    // wait and SD counters). 0 leaves it and its counters out (about 1,000
    // logic cells on the Nano 20K, which needs them for sound); the Pi debug
    // link, the keys (K, J) and the breakpoints stay.
    parameter integer STATUS_LINE = 1,
    // Hardware breakpoint slots (each about 80 ALU and 27 registers); writes
    // to a slot at or above this are ignored.
    parameter integer BREAKPOINT_SLOTS = 10,
    // 0: the Pi debug slave's SPI is driven by the FPGA's own master from the
    // debug UART (as above). 1: it is the board's pins pi_ce0_n, pi_sclk,
    // pi_mosi and pi_miso, for a real Raspberry Pi (the Nano 20K's Pi Zero);
    // the UART's Pi protocol is then unused.
    parameter integer PI_SPI_PINS = 0,
    // 1: the core's SPI master samples MISO half a CPU clock later
    // (spi_master g_miso_late), for boards whose SD clock reaches the card late.
    parameter integer SPI_MISO_LATE = 0,
    // Bit 0: the RZX input recorder on the debug UART (Z / z, above).
    // Bit 1: the RZX player on the debug UART (P, above).
    parameter integer RZX = 0,
    // The rewind ring (rtl/debug/nexttang_ring_control.v): checkpoints of
    // memory and registers on p, c, r and i from the debug UART. Needs the
    // FPGA-side SPI master (PI_SPI_PINS = 0), a memory port C that reaches
    // the whole of an 8 MiB die (ram_c_address_high), and RZX bit 0 for the
    // recorder's position.
    parameter integer REWIND_RING = 0,
    // 1: every frame exactly one HDMI frame long (zxula_timing's
    // i_frame_exact), for a board with a 27 MHz pixel clock that is 24/25 of
    // its 28 MHz and no other video output.
    parameter integer FRAME_EXACT = 0,
    // 1: a real-time clock in fabric at the DS1307's I2C address
    // (nexttang_rtc), set from the debug UART (C and fourteen digits) or by
    // NextZXOS; nothing keeps the time while the board is off.
    parameter integer RTC = 0,
    // 1: that clock's one-second counter in a GW2A DSP block (see nexttang_rtc).
    parameter integer RTC_DSP = 0,
    // clock_28's real frequency, for the RTC's second (Nano 20K: 28125000; at
    // 28000000 there the clock gained about 6.5 minutes a day)
    parameter integer MACHINE_HZ = 28000000
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
    output wire [1:0]  ram_c_address_high,   // 0 from the core; the rewind ring's copy and undo records
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
    // the Next keyboard's extra keys (i_KBD_EXTENDED_KEYS, 1 = pressed, as the
    // official membrane gives them; 16'h0000 with no Next-style keyboard), the keymap writes from NextREGs 0x28-0x2B
    // and NextREG 0x68 bit 4 (keep the extra keys out of the 8x5 matrix)
    input  wire [15:0] extended_keys,
    output wire [8:0]  keymap_address,
    output wire [7:0]  keymap_data,
    output wire        keymap_write,
    output wire        keyboard_cancel_extended,
    input  wire [10:1] function_keys,
    input  wire [11:0] left_joystick,
    input  wire [11:0] right_joystick,
    input  wire [7:0]  mouse_x,
    input  wire [7:0]  mouse_y,
    input  wire [2:0]  mouse_buttons,
    input  wire [3:0]  mouse_wheel,
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
    output wire        pi_miso,
    // The Pi's serial port, the Next's UART 1 (GPIO 14/15, NextREG 0xA0), as
    // a real Next's Pi Zero accelerator uses it: pi_uart_txd is the Pi's TXD
    // (its GPIO 14), pi_uart_rxd drives the Pi's RXD (its GPIO 15). Tie
    // pi_uart_txd high where there is no Pi.
    input  wire        pi_uart_txd,
    output wire        pi_uart_rxd,
    // The Pi's I2S audio into the Next (NextREG 0xA2; AlpineNext sets 0xD2:
    // the Pi is master and drives its data on GPIO 21): bit clock (Pi GPIO 18),
    // word clock (GPIO 19) and data (GPIO 21). Tie low where there is no Pi.
    input  wire        pi_i2s_bclk,
    input  wire        pi_i2s_lrclk,
    input  wire        pi_i2s_data,
    // The Next's UART 0, which a real Next wires to its ESP Wi-Fi module:
    // esp_uart_rx is the module's TX (asynchronous; the core's receiver
    // registers it twice and filters it, as on a real Next),
    // esp_uart_tx goes to the module's RX. Two wires: hardware flow control
    // is not supported (the core's CTS is held asserted). esp_reset is high
    // while NextREG 0x02 bit 7 holds the expansion bus and ESP in reset, which
    // software uses to recover a module that has stopped answering. Tie
    // esp_uart_rx high where there is nothing to answer.
    input  wire        esp_uart_rx,
    output wire        esp_uart_tx,
    output wire        esp_reset
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
    // With a Pi on the pins the slave is still the FPGA's own while its master
    // has a transfer under way (the rewind ring's checkpoints, or the debug
    // UART's bridge): until 2026-11-17 a PI_SPI_PINS build gave the slave to
    // the pins alone, so the ring's commands went nowhere. The ring waits for
    // the Pi's chip select to be idle before it starts (spi_free); a Pi that
    // begins a transfer during one of the FPGA's loses it.
    wire        own_spi = PI_SPI_PINS == 0 || !master_spi_ce_n;
    wire        pi_spi_ce_n = own_spi ? master_spi_ce_n : pin_ce_n_sync[1];
    wire        pi_spi_sclk = own_spi ? master_spi_sclk : pin_sclk_sync[1];
    wire        pi_spi_mosi = own_spi ? master_spi_mosi : pin_mosi_sync[1];
    wire        pin_spi_idle = PI_SPI_PINS == 0 || pin_ce_n_sync[1];
    wire [27:0] core_gpio;
    wire [27:0] core_gpio_en;
    reg  [1:0]  pi_uart_txd_meta = 2'b11;
    always @(posedge clock_28) pi_uart_txd_meta <= {pi_uart_txd_meta[0], pi_uart_txd};
    wire        pi_uart_txd_sync = pi_uart_txd_meta[1];
    reg  [5:0]  pi_i2s_meta = 6'd0;      // {data, lrclk, bclk} x 2 stages
    always @(posedge clock_28) pi_i2s_meta <= {pi_i2s_meta[2:0], pi_i2s_data, pi_i2s_lrclk, pi_i2s_bclk};
    wire        pi_i2s_bclk_sync = pi_i2s_meta[3];
    wire        pi_i2s_lrclk_sync = pi_i2s_meta[4];
    wire        pi_i2s_data_sync = pi_i2s_meta[5];
    assign      pi_uart_rxd = core_gpio_en[14] ? core_gpio[14]
                            : core_gpio_en[15] ? core_gpio[15] : 1'b1;
    // Hardware breakpoints (rtl/debug/nexttang_breakpoints.vhd).
    wire [15:0] cpu_next_pc;
    wire        cpu_stopped;
    wire        cpu_break;
    wire [63:0] core_mmu;
    wire        rzx_m1_n, rzx_iorq_n, rzx_rd_n, rzx_int_n;
    wire        rzx_playing, rzx_play_int;
    wire [7:0]  rzx_play_data;
    wire        rzx_play_taking;
    wire        rzx_play_hold;
    wire        rzx_play_record_after, rzx_play_desync, rzx_play_busy;
    wire [15:0] rzx_play_fetches;
    wire        rzx_takeover;        // a replay has just handed over to the recorder
    wire [15:0] rzx_frames, rzx_frame_fetches, rzx_frame_reads;   // the recorder's position
    // the core's own port C, and the SPI master's users, before the rewind ring's share
    wire [20:0] core_c_address;
    wire        core_c_request, core_c_read_n;
    wire [7:0]  core_c_write_data;
    wire        ring_c_take, ring_c_request, ring_c_read_n;
    wire [22:0] ring_c_address;
    wire [7:0]  ring_c_write_data;
    wire        ring_spi_take, ring_spi_select, ring_spi_byte_valid;
    wire [7:0]  ring_spi_byte;
    wire        ring_tx;
    wire        core_mreq_n;
    wire [7:0]  rzx_in_data;

    wire        core_m1_n;
    wire        core_wr_n;
    wire        core_rd_n;
    wire [7:0]  core_bus_data;
    wire        core_nr_write;
    wire [7:0]  core_nr_register;
    wire [7:0]  core_nr_data;
    wire        core_iorq_n;
    wire [15:0] core_bus_address;

    // The core's bit-banged I2C lines (1 released, 0 low) and the clock on them.
    wire i2c_scl, i2c_sda, rtc_sda;           // the clock itself is further down

    // Held from the debug UART (Y and M commands, parsed with K and J below).
    reg [11:0] host_joystick = 12'b0;
    reg [18:0] host_mouse = 19'b0;             // buttons, X, Y
    reg [1:0]  joystick_digits_left = 2'd0;
    reg [11:0] joystick_command_mask = 12'b0;
    reg [2:0]  mouse_digits_left = 3'd0;
    reg [18:0] mouse_command_mask = 19'b0;

    zxnext #(
        .g_video_def(3'b000),
        .g_version(8'h32),
        .g_sub_version(8'h05),   // official core 3.02.05
        .g_video_inc(2'b10),
        .g_layer2_units(LAYER2_UNITS),
        .g_spi_miso_late(SPI_MISO_LATE),
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
        .o_RESET_PERIPHERAL(esp_reset),
        .o_FLASH_BOOT(),
        .o_CORE_ID(),

        .i_SPKEY_FUNCTION(function_keys),   // F10 down to F1
        .i_SPKEY_BUTTONS(2'b0),
        .i_SPKEY_FUNCTION_EXT(5'b0),

        .o_KBD_CANCEL(keyboard_cancel_extended),
        .o_KBD_ROW(keyboard_rows),
        .i_KBD_COL(keyboard_columns),
        .i_KBD_EXTENDED_KEYS(extended_keys),
        .o_KEYMAP_ADDR(keymap_address),
        .o_KEYMAP_DATA(keymap_data),
        .o_KEYMAP_WE(keymap_write),
        .o_JOYMAP_WE(),
        .i_JOY_LEFT(left_joystick | host_joystick),
        .i_JOY_RIGHT(right_joystick),
        .o_JOY_IO_MODE_EN(),
        .o_JOY_IO_MODE_PIN_7(),
        .o_JOY_LEFT_TYPE(),
        .o_JOY_RIGHT_TYPE(),
        .i_MOUSE_X(mouse_x + host_mouse[15:8]),
        .i_MOUSE_Y(mouse_y + host_mouse[7:0]),
        .i_MOUSE_BUTTON(mouse_buttons | host_mouse[18:16]),
        .i_MOUSE_WHEEL(mouse_wheel),
        .o_PS2_MODE(),
        .o_MOUSE_CONTROL(),

        .i_I2C_SCL_n(i2c_scl),
        .i_I2C_SDA_n(i2c_sda & rtc_sda),
        .o_I2C_SCL_n(i2c_scl),
        .o_I2C_SDA_n(i2c_sda),

        .o_SPI_SS_FLASH_n(),
        .o_SPI_SS_SD1_n(),
        .o_SPI_SS_SD0_n(spi_sd0_select_n),
        .o_SPI_SCK(spi_clock),
        .o_SPI_MOSI(spi_mosi),
        .i_SPI_SD_MISO(spi_sd_miso),
        .i_SPI_FLASH_MISO(1'b1),

        .i_UART0_RX(esp_uart_rx),            // asynchronous: uart_rx registers it twice and filters it (debounce)
        .o_UART0_TX(esp_uart_tx),
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
        .i_CPU_WAIT(cpu_wait | rzx_play_hold),   // the RZX player waits for its stream

        .o_RAM_B_ADDR(layer2_address),
        .o_RAM_B_REQ_T(layer2_request_toggle),
        .o_RAM_B_PF_ADDR(layer2_prefetch_address),
        .o_RAM_B_PF_REQ_T(layer2_prefetch_toggle),
        .i_RAM_B_DI(layer2_data),

        .o_RAM_C_ADDR(core_c_address),
        .o_RAM_C_REQ(core_c_request),
        .o_RAM_C_RD_n(core_c_read_n),
        .i_RAM_C_DI(ram_c_read_data),
        .o_RAM_C_DO(core_c_write_data),
        .i_RAM_C_ACK(ram_c_ack && !ring_c_take),

        .o_BUS_ADDR(core_bus_address),
        .i_BUS_DI(8'hff),
        .o_BUS_DO(core_bus_data),
        .o_BUS_MREQ_n(core_mreq_n),
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
        // GPIO 14 and 15 carry UART 1 to the Pi. The core receives on GPIO 15
        // (or 14 with NextREG 0xA0 bit 5) and sends the same TX on whichever
        // of the two it enables, so the Pi's TXD feeds both inputs and the
        // Pi's RXD takes the core's TX from either.
        // GPIO 18-21 carry the Pi's I2S: clocks on 18/19 and its data on 21
        // (NextREG 0xA2 bit 4 set) or 20 (bit 4 clear); the data feeds both.
        .i_GPIO({6'b0, pi_i2s_data_sync, pi_i2s_data_sync, pi_i2s_lrclk_sync, pi_i2s_bclk_sync,
                 2'b0, pi_uart_txd_sync, pi_uart_txd_sync, 2'b0, pi_spi_sclk, pi_spi_mosi, 1'b0, pi_spi_ce_n, 8'b0}),
        .i_PI_SPI_SLAVE_FORCE(1'b1),
        .o_CPU_NEXT_PC(cpu_next_pc),
        .o_CPU_STOPPED(cpu_stopped),
        .i_CPU_BREAK(cpu_break),
        .o_MMU(core_mmu),
        .i_FRAME_EXACT(FRAME_EXACT != 0),
        .i_RZX_PLAY(rzx_playing),
        .i_RZX_INT(rzx_play_int),
        .i_RZX_IN_DATA(rzx_play_data),
        .o_RZX_M1_n(rzx_m1_n),
        .o_RZX_IORQ_n(rzx_iorq_n),
        .o_RZX_RD_n(rzx_rd_n),
        .o_RZX_INT_n(rzx_int_n),
        .o_RZX_IN_DATA(rzx_in_data),
        .o_GPIO(core_gpio),
        .o_GPIO_EN(core_gpio_en),

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

    // With STATUS_LINE 0 the status UART's inputs are constant and its output
    // is unused, so synthesis removes it with the counters that feed it; it
    // stays instantiated because the boards' SDCs name its registers.
    wire status_line_transmit;
    nexttang_debug_status_uart #(
        .CLOCK_HZ(7000000),
        .GAP_CLOCKS(1750000),
        .EXTRA_VALUE(5)
    ) status_uart (
        .clock(clock_7),
        .reset(!machine_locked),
        .flags(STATUS_LINE != 0 ? status_flags : 6'd0),
        .value(STATUS_LINE != 0 ? status_value : 32'd0),
        .extra(STATUS_LINE == 0 ? 160'd0 : {
            wait_holds_reported, wait_longest_reported,
            8'h00, wait_cycles_reported,
            last_io_write_data, sd_byte_count,
            sd_checksum,
            cpu_wait, cpu_contend, 2'b00, double_interrupts, cpu_enable_count
        }),
        .transmit(status_line_transmit)
    );
    assign status_transmit = STATUS_LINE != 0 ? status_line_transmit : 1'b1;

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
    assign     board_command_valid = command_valid && !pi_frame_active && !rzx_play_taking;
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
        .rx_valid(command_valid && !rzx_play_taking),
        .rx_byte(command_byte),
        .frame_active(pi_frame_active),
        .session_active(pi_session),
        .tx(pi_link_tx),
        .spi_select(pi_select),
        .spi_valid(pi_byte_valid),
        .spi_byte(pi_byte),
        .spi_ready(pi_byte_ready && !ring_spi_take),
        .spi_done(pi_reply_done && !ring_spi_take),
        .spi_reply(pi_reply),
        .spi_idle(pi_spi_idle && !ring_spi_take),
        .bp_strobe(bp_strobe),
        .bp_slot(bp_slot),
        .bp_enable(bp_enable),
        .bp_address(bp_address),
        .bp_paged(bp_paged),
        .bp_page(bp_page),
        .inject_pause(bp_hit | rzx_takeover)
    );

    nexttang_breakpoints #(
        .SLOTS(BREAKPOINT_SLOTS)
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

    // 3.5 MHz SCLK (HALF_CLOCKS 4; it was 8): the slave answers in time at
    // HALF_CLOCKS 3 since add72be (tests/sim/debug/tb_internal_spi_master.vhd),
    // and every debug-UART command and rewind-ring transfer takes half as long.
    nexttang_pi_spi_master #(.HALF_CLOCKS(4)) pi_debug_spi (
        .clock(clock_28),
        .reset(!machine_locked),
        .select_in(ring_spi_take ? ring_spi_select : pi_select),
        .byte_valid(ring_spi_take ? ring_spi_byte_valid : pi_byte_valid),
        .byte_in(ring_spi_take ? ring_spi_byte : pi_byte),
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

    generate
    if (RTC != 0) begin : rtc
        nexttang_rtc #(.CLOCK_HZ(MACHINE_HZ), .DSP_PRESCALER(RTC_DSP)) clock_chip (
            .clock(clock_28), .reset(!machine_locked),
            .scl(i2c_scl), .sda_in(i2c_sda), .sda_out(rtc_sda),
            .command_valid(board_command_valid), .command_byte(command_byte),
            .valid());
    end else begin : no_rtc
        assign rtc_sda = 1'b1;
    end
    endgenerate

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

            if (command_byte == "Y") begin
                joystick_digits_left <= 2'd3;
            end else if (joystick_digits_left != 2'd0 && command_is_digit) begin
                joystick_command_mask <= {joystick_command_mask[7:0], command_digit};
                joystick_digits_left <= joystick_digits_left - 2'd1;
                if (joystick_digits_left == 2'd1)
                    host_joystick <= {joystick_command_mask[7:0], command_digit};
            end else begin
                joystick_digits_left <= 2'd0;
            end

            if (command_byte == "M") begin
                mouse_digits_left <= 3'd5;
            end else if (mouse_digits_left != 3'd0 && command_is_digit) begin
                mouse_command_mask <= {mouse_command_mask[15:0], command_digit};
                mouse_digits_left <= mouse_digits_left - 3'd1;
                if (mouse_digits_left == 3'd1)
                    host_mouse <= {mouse_command_mask[14:0], command_digit};
            end else begin
                mouse_digits_left <= 3'd0;
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

    // RZX input recorder (RZX bit 0).
    wire rzx_busy;
    wire rzx_tx;
    generate
    if ((RZX & 1) != 0) begin : rzx
        wire recording, saturated, overflow;
        wire [8:0] word;
        wire word_valid, word_ready;
        wire [15:0] frames;
        assign rzx_frames = frames;
        reg  armed = 1'b0;
        reg  stopped_q = 1'b0;
        wire command_start = board_command_valid && command_byte == "Z";
        wire command_stop = board_command_valid && command_byte == "z";
        wire resumed = stopped_q && !cpu_stopped;
        // A replay that the host ended with FE 02 hands over to the recorder:
        // recording starts on the clock playing ends, already as many fetches
        // into its first frame as the player had counted since the last
        // frame it played, so the two recordings join without a seam. The
        // CPU is stopped there too (as at a breakpoint), for the host to put
        // the CPU speed back and resume when the player is ready. The marker
        // and the first words wait for the play link's last bytes to leave.
        reg  playing_q = 1'b0;
        reg  begin_wait = 1'b0;
        reg [1:0] stopped_h = 2'b00;
        assign rzx_takeover = playing_q && !rzx_playing && rzx_play_record_after &&
                              !rzx_play_desync && !recording;
        wire start = (command_start && !cpu_stopped && !recording) || (armed && resumed) || rzx_takeover;
        wire begin_stream = (start && !rzx_takeover) || (begin_wait && !rzx_play_busy);
        reg  stop_q = 1'b0;

        always @(posedge clock_28) begin
            playing_q <= rzx_playing;
            stopped_h <= {stopped_h[0], cpu_stopped};
            if (rzx_takeover)
                begin_wait <= 1'b1;
            else if (!rzx_play_busy || !machine_locked)
                begin_wait <= 1'b0;
            stopped_q <= cpu_stopped;
            stop_q <= command_stop && recording;
            if (command_start && cpu_stopped && !recording)
                armed <= 1'b1;
            if (start || command_stop || !machine_locked)
                armed <= 1'b0;
        end

        nexttang_rzx_logger #(
            .FIFO_BITS(6)
        ) logger (
            .clock(clock_28),
            .reset(!machine_locked),
            .start(start),
            .start_fetches(rzx_takeover ? rzx_play_fetches : 16'd0),
            .stop(command_stop),
            .recording(recording),
            .m1_n(rzx_m1_n),
            .iorq_n(rzx_iorq_n),
            .rd_n(rzx_rd_n),
            .data(rzx_in_data),
            // interrupts that pass while the CPU is stopped end no frame
            .int_n(rzx_int_n | cpu_stopped),
            .int_cut(cpu_stopped && !stopped_h[1]),
            .word(word),
            .word_valid(word_valid),
            .word_ready(word_ready),
            .frames(frames),
            .frame_fetches(rzx_frame_fetches),
            .frame_reads(rzx_frame_reads),
            .saturated(saturated),
            .overflow(overflow)
        );

        // The end marker's flags and count are taken a clock after the stop,
        // when the recorder has settled.
        nexttang_rzx_uart #(
            .CLOCK_HZ(28000000),
            .BAUD_RATE(115200)
        ) sender (
            .clock(clock_28),
            .reset(!machine_locked),
            .begin_stream(begin_stream),
            .end_stream(stop_q),
            .end_flags({overflow, saturated}),
            .end_frames(frames),
            .word(word),
            .word_valid(word_valid),
            .word_ready(word_ready),
            .busy(rzx_busy),
            .tx(rzx_tx)
        );
    end else begin : no_rzx
        assign rzx_busy = 1'b0;
        assign rzx_tx = 1'b1;
        assign rzx_takeover = 1'b0;
        assign rzx_frames = 16'd0;
        assign rzx_frame_fetches = 16'd0;
        assign rzx_frame_reads = 16'd0;
    end
    endgenerate

    // RZX player (RZX bit 1).
    wire rzx_play_tx;
    generate
    if ((RZX & 2) != 0) begin : rzx_play
        wire play_start, play_stop;
        wire desync = rzx_play_desync;
        wire [15:0] frames;
        wire [7:0] stream_byte;
        wire stream_valid, stream_ready;

        nexttang_rzx_play_link #(
            .CLOCK_HZ(28000000),
            .BAUD_RATE(115200),
            .FIFO_BITS(10)
        ) link (
            .clock(clock_28),
            .reset(!machine_locked),
            .command_valid(command_valid && (!pi_frame_active || rzx_play_taking)),
            .command_byte(command_byte),
            .taking(rzx_play_taking),
            .cpu_stopped(cpu_stopped),
            .play_start(play_start),
            .play_stop(play_stop),
            .record_after(rzx_play_record_after),
            .playing(rzx_playing),
            .desync(desync),
            .frames(frames),
            .byte_out(stream_byte),
            .byte_valid(stream_valid),
            .byte_ready(stream_ready),
            .busy(rzx_play_busy),
            .tx(rzx_play_tx)
        );

        nexttang_rzx_player player (
            .clock(clock_28),
            .reset(!machine_locked),
            .start(play_start),
            .stop(play_stop),
            .playing(rzx_playing),
            .desync(rzx_play_desync),
            .frames(frames),
            .fetch_count(rzx_play_fetches),
            .m1_n(rzx_m1_n),
            .iorq_n(rzx_iorq_n),
            .rd_n(rzx_rd_n),
            .byte_in(stream_byte),
            .byte_valid(stream_valid),
            .byte_ready(stream_ready),
            .in_data(rzx_play_data),
            .int_request(rzx_play_int),
            .hold(rzx_play_hold)
        );
    end else begin : no_rzx_play
        assign rzx_playing = 1'b0;
        assign rzx_play_int = 1'b0;
        assign rzx_play_data = 8'hff;
        assign rzx_play_taking = 1'b0;
        assign rzx_play_hold = 1'b0;
        assign rzx_play_busy = 1'b0;
        assign rzx_play_tx = 1'b1;
        assign rzx_play_record_after = 1'b0;
        assign rzx_play_desync = 1'b0;
        assign rzx_play_fetches = 16'd0;
    end
    endgenerate

    assign pi_miso = core_gpio[9];

    // Rewind ring (REWIND_RING).
    generate
    if (REWIND_RING != 0) begin : rewind_ring
        // What the machine writes. Main memory writes are port A's. Bank 5
        // and the first half of bank 7 are block RAM inside the core and
        // never reach port A, so those are taken from the bus: a memory
        // write to a slot whose MMU page is 0A, 0B or 0E. (A write there
        // that divMMC or a Layer 2 mapping diverts marks a block that did
        // not change, which only costs a copy.)
        wire       bank_write = !core_mreq_n && !core_wr_n;
        wire [7:0] bank_page = core_mmu[{core_bus_address[15:13], 3'b000} +: 8];
        reg        bank_write_q = 1'b0;
        reg        bank_strobe = 1'b0;
        reg [20:0] bank_address = 21'd0;
        reg [7:0]  bank_data = 8'h00;
        always @(posedge clock_28) begin
            bank_data <= core_bus_data;
            bank_write_q <= bank_write;
            bank_strobe <= bank_write && !bank_write_q &&
                           (bank_page == 8'h0a || bank_page == 8'h0b || bank_page == 8'h0e);
            bank_address <= 21'h040000 + {bank_page, core_bus_address[12:0]};
        end
        nexttang_ring_control #(
            .CLOCK_HZ(28000000),
            .BAUD_RATE(115200)
        ) ring (
            .clock(clock_28),
            .reset(!machine_locked),
            .command_valid(board_command_valid),
            .command_byte(command_byte),
            .busy(),
            .cpu_stopped(cpu_stopped),
            .frames(rzx_frames),
            .frame_fetches(rzx_frame_fetches),
            .frame_reads(rzx_frame_reads),
            .write_valid((ram_a_request && ram_a_read_n) || bank_strobe),
            .write_address(bank_strobe ? bank_address : ram_a_address),
            .bank_valid(bank_strobe),
            .bank_address(bank_address),
            .bank_data(bank_data),
            .c_free(!core_c_request && !ram_c_busy),
            .spi_free(!pi_frame_active && pin_spi_idle),
            .spi_take(ring_spi_take),
            .spi_select(ring_spi_select),
            .spi_byte_valid(ring_spi_byte_valid),
            .spi_byte(ring_spi_byte),
            .spi_byte_ready(pi_byte_ready),
            .spi_done(pi_reply_done),
            .spi_reply(pi_reply),
            .spi_idle(pi_spi_idle),
            .c_take(ring_c_take),
            .c_request(ring_c_request),
            .c_read_n(ring_c_read_n),
            .c_address(ring_c_address),
            .c_write_data(ring_c_write_data),
            .c_read_data(ram_c_read_data),
            .c_ack(ram_c_ack && ring_c_take),
            .tx(ring_tx)
        );
    end else begin : no_rewind_ring
        assign ring_c_take = 1'b0;
        assign ring_c_request = 1'b0;
        assign ring_c_read_n = 1'b1;
        assign ring_c_address = 23'd0;
        assign ring_c_write_data = 8'h00;
        assign ring_spi_take = 1'b0;
        assign ring_spi_select = 1'b0;
        assign ring_spi_byte_valid = 1'b0;
        assign ring_spi_byte = 8'h00;
        assign ring_tx = 1'b1;
    end
    endgenerate
    assign ram_c_address = ring_c_take ? ring_c_address[20:0] : core_c_address;
    assign ram_c_address_high = ring_c_take ? ring_c_address[22:21] : 2'b00;
    assign ram_c_read_n = ring_c_take ? ring_c_read_n : core_c_read_n;
    assign ram_c_write_data = ring_c_take ? ring_c_write_data : core_c_write_data;
    nexttang_port_c_handover handover (
        .clock(clock_28), .ring_take(ring_c_take), .ring_request(ring_c_request),
        .core_request(core_c_request), .request(ram_c_request)
    );

    assign debug_uart_tx = (rzx_play_busy ? rzx_play_tx
                          : rzx_busy ? rzx_tx
                          : pi_session ? pi_link_tx
                          : capture_sending ? capture_transmit
                          : trace_frozen ? trace_transmit
                          : log_sending ? log_transmit
                          : status_transmit) & ring_tx;
endmodule

`default_nettype wire

// Memory port C's request line, shared by the rewind ring and the core's
// debug slave. The board's memory takes a request as new only once the line
// has been low since its last ack. The ring lets go a cycle after its ack,
// and if the core's request was already waiting behind it the line went from
// the ring's request straight to the core's without a low cycle: the core's
// request was never started and the debug slave waited for ever, dead to the
// Pi and the debug UART alike. It took a CPU write to bank 5 or 7 (the ring
// mirrors each one into the SDRAM) landing just before a debug memory access;
// found with a Pi sending 4 KiB blocks while a game drew its screen
// (2026-11-21). The core's request is now held off the line for the one
// cycle after the ring lets go.
module nexttang_port_c_handover (
    input  wire clock,
    input  wire ring_take,
    input  wire ring_request,
    input  wire core_request,
    output wire request
);
    reg ring_take_q = 1'b0;
    always @(posedge clock) ring_take_q <= ring_take;
    assign request = ring_take ? ring_request : (core_request && !ring_take_q);
endmodule
