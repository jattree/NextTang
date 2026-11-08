// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// ZX Spectrum Next for the Tang Nano 20K (v3923): the board shell.
//
// Status: PLANNED SKELETON. This file fixes the shell's pins and how it
// meets the shared machine (rtl/platform/nexttang_next_machine.v); it does
// not yet make a working image and has never been built for or run on a
// Nano. What is missing, each a block of its own (port plan 2026-11-06,
// sections 2.3 to 2.5):
//
//   clocks    two rPLLs: 27 MHz x 5 for the HDMI serializer and its 27 MHz
//             pixel clock, and the machine and SDRAM clocks (candidate
//             settings in the plan, unverified against UG286 limits).
//   memory    nexttang_sdr_sdram_service, our own SDR controller (NextNano's
//             is GPL and descends from MiSTer; we write our own): port A with
//             cpu_wait, port B with a reserved Layer 2 slot (NextNano #13),
//             port C in the background, refresh outside the Layer 2 window.
//   video     the official hdmi_frame (576p50/480p60 locked to the core's
//             frame) into hdl-util TMDS and a GW2A OSER10/ELVDS serializer.
//   input     the BL616 FPGA-Companion SPI into keyboard rows and joysticks.
//   audio     PCM to the I2S amplifier and HDMI audio packets.
//   debug     the Pi0 on the official Pi debug slave's SPI pins; the machine
//             today drives that slave from its own UART-fed master, so a
//             PI_SPI_PINS option on the machine is part of this work.
//
// Until those exist every output below is held in a safe idle state, and
// the build driver refuses to build this board. Capability limits on this
// part (inferred from the 2026-11-06 synthesis probe): no Spec256, no Layer 2
// block-RAM mirror, no DDR3 frame store or 720p scaler.

`default_nettype none

module nexttang_nano20k_zxnext (
    input  wire        clock_27,

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,

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
    inout  wire [31:0] IO_sdram_dq,

    output wire        sd_clk,
    output wire        sd_mosi,
    output wire        sd_cs,
    input  wire        sd_miso,
    output wire        sd_dat1,
    output wire        sd_dat2,

    input  wire        companion_cs_n,
    input  wire        companion_sclk,
    input  wire        companion_mosi,
    output wire        companion_miso,
    output wire        companion_irq_n,

    output wire        amp_enable,
    output wire        amp_data,
    output wire        amp_lrck,
    output wire        amp_bclk,

    input  wire [1:0]  button,
    output wire [5:0]  led,

    input  wire        pi_ce0_n,
    output wire        pi_miso,
    input  wire        pi_mosi,
    input  wire        pi_sclk,
    input  wire        debug_uart_rx,
    output wire        debug_uart_tx
);
    // ----------------------------------------------------------------- clocks
    // PLANNED: rPLL-derived clocks. Tied low, the machine never leaves reset.
    wire clock_28 = 1'b0;
    wire clock_28_n = 1'b1;
    wire clock_14 = 1'b0;
    wire clock_7 = 1'b0;
    wire psg_enable = 1'b0;
    wire machine_locked = 1'b0;
    wire machine_reset = 1'b1;

    // ---------------------------------------------------------------- machine
    wire [20:0] ram_a_address;
    wire        ram_a_request;
    wire        ram_a_cycle_request;
    wire        ram_a_read_n;
    wire [7:0]  ram_a_write_data;
    wire [20:0] layer2_address;
    wire        layer2_request_toggle;
    wire [20:0] ram_c_address;
    wire        ram_c_request;
    wire        ram_c_read_n;
    wire [7:0]  ram_c_write_data;
    wire [8:0]  core_rgb;
    wire        core_hsync_n;
    wire        core_vsync_n;
    wire        core_blank_n;
    wire        core_video_60;
    wire        core_hdmi_pixel;
    wire        core_hdmi_lock;
    wire        core_hdmi_reset;
    wire [12:0] core_audio_left;
    wire [12:0] core_audio_right;
    wire [7:0]  keyboard_rows;
    wire [39:0] host_keys;
    wire [10:1] host_functions;
    wire        spi_clock;
    wire        spi_mosi;
    wire        spi_sd0_select_n;
    wire        board_command_valid;
    wire [7:0]  board_command_byte;

    // Layer 2 comes straight from SDRAM through a reserved slot, so every
    // unit can be served once the SDR service exists; until then none is.
    localparam [127:0] LAYER2_UNITS = 128'd0;
    // CPU with the debug interface, every Pi slave command, port C.
    localparam [15:0]  CORE_OPTION = 16'hFFF2;

    nexttang_next_machine #(
        .LAYER2_UNITS(LAYER2_UNITS),
        .CORE_OPTION(CORE_OPTION),
        .SD_MONITOR(1)
    ) machine (
        .clock_28(clock_28),
        .clock_28_n(clock_28_n),
        .clock_14(clock_14),
        .clock_7(clock_7),
        .psg_enable(psg_enable),
        .machine_reset(machine_reset),
        .machine_locked(machine_locked),

        .ram_a_address(ram_a_address),
        .ram_a_address_21(),
        .ram_a_request(ram_a_request),
        .ram_a_cycle_request(ram_a_cycle_request),
        .ram_a_read_n(ram_a_read_n),
        .ram_a_write_data(ram_a_write_data),
        .ram_a_read_data(8'hff),          // PLANNED: SDR service port A
        .cpu_wait(1'b0),

        .layer2_address(layer2_address),
        .layer2_request_toggle(layer2_request_toggle),
        .layer2_data(8'h00),              // PLANNED: SDR service port B

        .ram_c_address(ram_c_address),
        .ram_c_request(ram_c_request),
        .ram_c_read_n(ram_c_read_n),
        .ram_c_write_data(ram_c_write_data),
        .ram_c_read_data(8'h00),          // PLANNED: SDR service port C
        .ram_c_ack(1'b0),
        .ram_c_busy(1'b0),
        .memory_faults(3'b000),

        .core_rgb(core_rgb),
        .core_hsync_n(core_hsync_n),
        .core_vsync_n(core_vsync_n),
        .core_blank_n(core_blank_n),
        .core_video_60(core_video_60),
        .core_hdmi_pixel(core_hdmi_pixel),
        .core_hdmi_lock(core_hdmi_lock),
        .core_hdmi_reset(core_hdmi_reset),
        .video_clock_locked(1'b0),
        .capture_frame_start(1'b0),
        .capture_pixel_valid(1'b0),
        .capture_x(9'd0),
        .capture_y(9'd0),
        .capture_pixel(9'd0),
        .capture_protocol_error(1'b0),
        .frame_store_fault(1'b0),

        .core_audio_left(core_audio_left),
        .core_audio_right(core_audio_right),

        .keyboard_rows(keyboard_rows),
        .keyboard_columns(5'b11111),      // PLANNED: BL616 companion
        .function_keys(10'b0),
        .left_joystick(12'b0),
        .right_joystick(12'b0),
        .keyboard_connected(1'b0),
        .input_active(1'b0),
        .host_keys(host_keys),
        .host_functions(host_functions),

        .spi_clock(spi_clock),
        .spi_mosi(spi_mosi),
        .spi_sd0_select_n(spi_sd0_select_n),
        .spi_sd_miso(sd_miso),

        .debug_uart_rx(debug_uart_rx),
        .debug_uart_tx(debug_uart_tx),
        .board_command_valid(board_command_valid),
        .board_command_byte(board_command_byte)
    );

    // ------------------------------------------------------- idle outputs
    // SD on the core's SPI. PLANNED: register SCK, MOSI and MISO at the pins,
    // as spi_master expects (NextNano drives them combinationally, the
    // strongest lead for its card corruption, issue #3).
    assign sd_clk = spi_clock;
    assign sd_mosi = spi_mosi;
    assign sd_cs = spi_sd0_select_n;
    assign sd_dat1 = 1'b1;
    assign sd_dat2 = 1'b1;

    // SDRAM deselected.
    assign O_sdram_clk = 1'b0;
    assign O_sdram_cke = 1'b0;
    assign O_sdram_cs_n = 1'b1;
    assign O_sdram_cas_n = 1'b1;
    assign O_sdram_ras_n = 1'b1;
    assign O_sdram_wen_n = 1'b1;
    assign O_sdram_addr = 11'd0;
    assign O_sdram_ba = 2'd0;
    assign O_sdram_dqm = 4'hf;
    assign IO_sdram_dq = 32'bz;

    // HDMI idle. PLANNED: GW2A serializer through ELVDS_OBUF.
    assign tmds_clk_p = 1'b0;
    assign tmds_clk_n = 1'b1;
    assign tmds_d_p = 3'b000;
    assign tmds_d_n = 3'b111;

    assign companion_miso = 1'b1;
    assign companion_irq_n = 1'b1;
    assign amp_enable = 1'b0;
    assign amp_data = 1'b0;
    assign amp_lrck = 1'b0;
    assign amp_bclk = 1'b0;
    assign pi_miso = 1'b1;
    // LED polarity is unverified on this board; held high for now.
    assign led = 6'b111111;
endmodule

`default_nettype wire
