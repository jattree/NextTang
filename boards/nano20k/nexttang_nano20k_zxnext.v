// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// ZX Spectrum Next for the Tang Nano 20K (v3923): the board shell.
//
// Status: FIRST BUILD, never run on a Nano. What it has:
//
//   clocks    rPLL 1: 27 MHz -> 84.375 MHz (SDRAM) and, through its
//             divide-by-3 output, 28.125 MHz for the machine (0.45 percent
//             fast, as NextNano);
//             CLKDIVs make 14 and 7 MHz from it. rPLL 2: 27 MHz x 5 for the
//             HDMI serializer, CLKDIV /5 for the 27 MHz pixel clock.
//   memory    nexttang_sdr_sdram_service: ports A and C from the in-package
//             SDRAM, and port B (Layer 2) prefetched from the core's
//             lookahead announcements (o_RAM_B_PF_*). Late Layer 2 bytes
//             set the status line's overrun flag.
//   video     the official hdmi_frame (576p50 / 480p60 from the core's own
//             frame, through a line buffer) into nexttang_tmds_encoder and
//             OSER10 / TLVDS_OBUF, as DVI (no audio yet). The pixel clock
//             comes from the crystal, not locked to the core's frame as on
//             the official board, so hdmi_frame re-locks every frame
//             (G_RELOCK, a NextTang option): the counters jump a few lines
//             within the vertical back porch.
//   input     keys from the host over the debug UART (the machine's K and J
//             commands), plus a USB keyboard through the BL616 (below).
//   debug     the debug UART on header pins 29 (TX) / 30 (RX) and on the
//             BL616's USB serial (FPGA pins 69 TX / 70 RX with Sipeed's stock
//             firmware); the two RX lines are ANDed, TX goes to both. Pin 69
//             is the companion IRQ under NextNano's firmware; a UART there is
//             harmless to it.
//
//   Pi0       the official Pi debug slave on header pins 25 CE0, 26 MISO,
//             27 MOSI, 28 SCLK (PI_SPI_PINS), for a Pi Zero.
//
//   audio     build option AUDIO (build_zxnext.sh --audio, with
//             --status-line 0 to make room): the core's stereo to the
//             HDMI stream (1, the default) and/or to the on-board MAX98357A
//             amplifier over I2S (2, built and booting, not yet listened to).
//
//   keyboard  also a USB keyboard on the Nano's USB-C port through an OTG
//             splitter, read by the BL616 running FPGA-Companion firmware
//             (nexttang_companion_keyboard, build option COMPANION, off by
//             default); simulated; on the board it boots 10 of 10 with no
//             phantom keys; real keys not yet tested (they need the Nano off
//             the laptop, since the BL616 stays a programmer with a PC on it).
// Capability limits on this part (2026-11-06 synthesis probe): no Spec256,
// no Layer 2 block-RAM mirror, no DDR3 frame store or 720p scaler.

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
    output wire        debug_uart_tx,
    input  wire        usb_uart_rx       // BL616 USB serial, FPGA pin 70
);
    // ----------------------------------------------------------------- clocks
    wire memory_clock;      // 84.375 MHz
    wire clock_28;          // 28.125 MHz
    wire machine_pll_lock;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"),
        .IDIV_SEL(7),        // 27 / 8 = 3.375 MHz
        .FBDIV_SEL(24),      // x 25 = 84.375 MHz
        .ODIV_SEL(8),        // VCO 675 MHz
        .DYN_SDIV_SEL(2),
        .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),   // CLKOUTD3 = 84.375 / 3 = 28.125 MHz
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0), .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false")
    ) machine_pll (
        .CLKIN(clock_27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0), .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(memory_clock), .LOCK(machine_pll_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(clock_28)
    );
    wire clock_14, clock_7;
    CLKDIV #(.DIV_MODE("2"), .GSREN("false")) divide_14 (
        .HCLKIN(clock_28), .RESETN(machine_pll_lock), .CALIB(1'b0), .CLKOUT(clock_14));
    CLKDIV #(.DIV_MODE("4"), .GSREN("false")) divide_7 (
        .HCLKIN(clock_28), .RESETN(machine_pll_lock), .CALIB(1'b0), .CLKOUT(clock_7));
    wire clock_28_n = ~clock_28;

    wire serial_clock;      // 135 MHz
    wire pixel_clock;       // 27 MHz
    wire video_pll_lock;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2AR-18C"),
        .IDIV_SEL(0), .FBDIV_SEL(4), .ODIV_SEL(4),   // 135 MHz, VCO 540 MHz
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0), .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false")
    ) video_pll (
        .CLKIN(clock_27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0), .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0),
        .CLKOUT(serial_clock), .LOCK(video_pll_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3()
    );
    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) divide_pixel (
        .HCLKIN(serial_clock), .RESETN(video_pll_lock), .CALIB(1'b0), .CLKOUT(pixel_clock));

    // memory first, then the machine
    wire memory_reset;
    nexttang_reset_release memory_reset_release (
        .clock(memory_clock), .asynchronous_reset(!machine_pll_lock), .reset(memory_reset));
    wire memory_ready;
    wire memory_timeout;
    wire machine_locked = machine_pll_lock;
    wire machine_reset;
    nexttang_reset_release machine_reset_release (
        .clock(clock_28), .asynchronous_reset(!machine_pll_lock || !memory_ready), .reset(machine_reset));
    wire psg_enable;
    nexttang_machine_clock_enables machine_enables (
        .clock_28(clock_28), .reset(machine_reset), .psg_enable(psg_enable));

    // ---------------------------------------------------------------- machine
    wire [20:0] ram_a_address;
    wire        ram_a_request;
    wire        ram_a_cycle_request;
    wire        ram_a_read_n;
    wire [7:0]  ram_a_write_data;
    wire [20:0] layer2_address;
    wire        layer2_request_toggle;
    wire [20:0] layer2_prefetch_address;
    wire        layer2_prefetch_toggle;
    wire [7:0]  layer2_data;
    wire [15:0] layer2_late, layer2_mismatch;
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
    wire [4:0]  keyboard_columns;
    wire [7:0]  ram_a_read_data;
    wire        cpu_wait;
    wire [7:0]  ram_c_read_data;
    wire        ram_c_ack;
    wire        ram_c_busy;
    wire [39:0] host_keys;
    wire [10:1] host_functions;
    wire        spi_clock;
    wire        spi_mosi;
    wire        spi_sd0_select_n;
    wire        board_command_valid;
    wire [7:0]  board_command_byte;

    // Layer 2 from the SDRAM through port B (prefetched from the core's
    // lookahead), in every unit.
    localparam [127:0] LAYER2_UNITS = {128{1'b1}};
    // CPU with the debug interface, every Pi slave command, port C.
    localparam [15:0]  CORE_OPTION = 16'hFFF2;
    // Build options (build_zxnext.sh --audio, --status-line, --pi-pins sets
    // these lines in its copy of this file).
    // AUDIO: the core's sound, bit 0 in the HDMI stream, bit 1 to the
    // on-board amplifier (see the audio section); 0 none.
    localparam integer AUDIO = 1;
    // STATUS_LINE: the machine's status line on the debug UART.
    localparam integer STATUS_LINE = 0;
    // PI_SPI_PINS: 1 the Pi Zero on header pins 25-28; 0 the debugger over the
    // debug UART (FT232R on 29/30, or the BL616's USB serial).
    localparam integer PI_SPI_PINS = 0;
    // COMPANION: answer the BL616's FPGA-Companion firmware and take a USB
    // keyboard from it. The BL616's FPGA Partner loader stays the programmer
    // when a PC is on the USB-C port and runs the Companion (USB host for the
    // keyboard) when one is not, e.g. power and keyboard through a splitter.
    // 2026-11-12: with the laptop attached this image kept the BL616 a
    // programmer for 5 minutes and 10 of 10 reloads, no phantom keys, the
    // FT232 debugger answering. An earlier build that drove the status-line
    // UART onto pin 69 (the Companion's level-low IRQ) made the BL616 drop off
    // USB until a power cycle; pin 69 now idles high once the Companion is
    // seen. Off by default until real keys have been tested on the board.
    localparam integer COMPANION = 0;

    // keys and F1-F10 held from the host over the debug UART
    reg [39:0] keys_meta = 40'd0, keys_sync = 40'd0;
    reg [10:1] functions_meta = 10'd0, functions_sync = 10'd0;
    always @(posedge clock_28) begin
        keys_meta <= host_keys; keys_sync <= keys_meta;
        functions_meta <= host_functions; functions_sync <= functions_meta;
    end
    // A USB keyboard through the on-board BL616 running FPGA-Companion (a USB-C
    // OTG splitter on the Nano's port): its SPI on pins 86/13/76/75
    // (nexttang_companion_keyboard). Its keys and F-keys add to the host's.
    wire [39:0] companion_keys;
    wire [10:1] companion_functions;
    wire        companion_seen;
    wire        companion_message;
    reg         companion_message_seen = 1'b0;
    generate
    if (COMPANION != 0) begin : companion
        nexttang_companion_keyboard companion_keyboard (
            .clock(clock_28), .reset(machine_reset),
            .spi_cs_n(companion_cs_n), .spi_sclk(companion_sclk), .spi_mosi(companion_mosi),
            .spi_miso(companion_miso),
            .keys(companion_keys), .function_keys(companion_functions),
            .seen(companion_seen), .keyboard_message(companion_message));
        always @(posedge clock_28)
            if (companion_message) companion_message_seen <= 1'b1;
    end else begin : no_companion
        assign companion_keys = 40'd0;
        assign companion_functions = 10'd0;
        assign companion_seen = 1'b0;
        assign companion_message = 1'b0;
        assign companion_miso = 1'b1;
    end
    endgenerate
    wire [39:0] all_keys = keys_sync | companion_keys;
    nexttang_keyboard_matrix keyboard_scan (
        .row_select(keyboard_rows), .keys(all_keys), .columns(keyboard_columns));
    wire uart_tx;

    nexttang_next_machine #(
        .LAYER2_UNITS(LAYER2_UNITS),
        .CORE_OPTION(CORE_OPTION),
        .SD_MONITOR(STATUS_LINE),         // reported on the status line
        .DEBUG_TAPS(0),                   // the block RAMs go to video and Layer 2
        .STATUS_LINE(STATUS_LINE),
        // Two breakpoint slots, not ten: about 700 logic cells back. Builds
        // above about 86 percent full met timing on paper and failed on the
        // board (2026-11-12); builds at 82-83 percent booted every time.
        .BREAKPOINT_SLOTS(2),
        .PI_SPI_PINS(PI_SPI_PINS),
        // SD MISO sampled half a CPU clock later: SCK leaves through an
        // I/O-cell register half a clock after the core moves it, so with the
        // official sampling point the card had 7.4 ns of the SD spec's 14 at
        // 28 MHz (nano20k_zxnext.sdc); about 25 ns this way.
        .SPI_MISO_LATE(1)
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
        .ram_a_read_data(ram_a_read_data),
        .cpu_wait(cpu_wait),

        .layer2_address(layer2_address),
        .layer2_request_toggle(layer2_request_toggle),
        .layer2_prefetch_address(layer2_prefetch_address),
        .layer2_prefetch_toggle(layer2_prefetch_toggle),
        .layer2_data(layer2_data),

        .ram_c_address(ram_c_address),
        .ram_c_request(ram_c_request),
        .ram_c_read_n(ram_c_read_n),
        .ram_c_write_data(ram_c_write_data),
        .ram_c_read_data(ram_c_read_data),
        .ram_c_ack(ram_c_ack),
        .ram_c_busy(ram_c_busy),
        .memory_faults({memory_timeout, layer2_late != 16'd0, 1'b0}),

        .core_rgb(core_rgb),
        .core_hsync_n(core_hsync_n),
        .core_vsync_n(core_vsync_n),
        .core_blank_n(core_blank_n),
        .core_video_60(core_video_60),
        .core_hdmi_pixel(core_hdmi_pixel),
        .core_hdmi_lock(core_hdmi_lock),
        .core_hdmi_reset(core_hdmi_reset),
        .video_clock_locked(video_pll_lock),
        .capture_frame_start(1'b0),
        .capture_pixel_valid(1'b0),
        .capture_x(9'd0),
        .capture_y(9'd0),
        .capture_pixel(9'd0),
        .capture_protocol_error(companion_message_seen),   // status line: a Companion keyboard message arrived
        .frame_store_fault(1'b0),

        .core_audio_left(core_audio_left),
        .core_audio_right(core_audio_right),

        .keyboard_rows(keyboard_rows),
        .keyboard_columns(keyboard_columns),
        .function_keys(functions_sync | companion_functions),
        .left_joystick(12'b0),
        .right_joystick(12'b0),
        .keyboard_connected(companion_seen),                 // status line: the BL616's Companion answered
        .input_active(|all_keys),
        .host_keys(host_keys),
        .host_functions(host_functions),

        .spi_clock(spi_clock),
        .spi_mosi(spi_mosi),
        .spi_sd0_select_n(spi_sd0_select_n),
        .spi_sd_miso(sd_miso),

        // With the Companion running, pins 69/70 are not the BL616's serial
        // link any more: ignore 70 (its noise read as key commands) and keep
        // 69 high.
        .debug_uart_rx(debug_uart_rx && (usb_uart_rx || companion_seen)),
        .debug_uart_tx(uart_tx),
        .board_command_valid(board_command_valid),
        .board_command_byte(board_command_byte),
        .pi_ce0_n(pi_ce0_n),
        .pi_sclk(pi_sclk),
        .pi_mosi(pi_mosi),
        .pi_miso(pi_miso)
    );

    // ------------------------------------------------------------ memory
    // SDRAM read capture: 1 falling edge (bring-up capture B), 0 rising edge
    // half a cycle earlier (capture A). Set from what bringup2 shows.
    localparam integer SDRAM_CAPTURE = 1;
    nexttang_sdr_sdram_service #(.CAPTURE(SDRAM_CAPTURE)) sdram (
        .machine_clock(clock_28), .memory_clock(memory_clock), .reset(memory_reset), .ready(memory_ready),
        .a_request(ram_a_request), .a_cycle_request(ram_a_cycle_request), .a_read_n(ram_a_read_n),
        .a_address(ram_a_address), .a_write_data(ram_a_write_data),
        .a_read_data(ram_a_read_data), .a_wait(cpu_wait),
        .c_request(ram_c_request), .c_read_n(ram_c_read_n), .c_address(ram_c_address),
        .c_write_data(ram_c_write_data), .c_read_data(ram_c_read_data), .c_ack(ram_c_ack), .c_busy(ram_c_busy),
        .fault_timeout(memory_timeout),
        .b_pf_toggle(layer2_prefetch_toggle), .b_pf_address(layer2_prefetch_address),
        .b_toggle(layer2_request_toggle), .b_address(layer2_address),
        .b_data(layer2_data), .b_late(layer2_late), .b_mismatch(layer2_mismatch),
        .sdram_clk(), .sdram_cke(O_sdram_cke), .sdram_cs_n(O_sdram_cs_n),
        .sdram_ras_n(O_sdram_ras_n), .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n),
        .sdram_addr(O_sdram_addr), .sdram_ba(O_sdram_ba), .sdram_dqm(O_sdram_dqm), .sdram_dq(IO_sdram_dq)
    );
    // The SDRAM clock leaves through an output DDR register in its I/O cell
    // (low after the rising edge, high after the falling edge: memory_clock
    // inverted, as the service's own sdram_clk), so its delay to the pin is the
    // same in every build. Taken straight from the fabric (~memory_clock), it
    // moved with placement, and so did the read capture point: a build that
    // met timing failed to boot NextZXOS while its neighbour booted
    // (2026-11-11). The build also puts the command, address and data
    // registers in their I/O cells (ireg/oreg/ioreg_in_iob).
    ODDR #(.TXCLK_POL(1'b0), .INIT(1'b0)) sdram_clock_out (
        .D0(1'b0), .D1(1'b1), .TX(1'b0), .CLK(memory_clock), .Q0(O_sdram_clk), .Q1());


    // ------------------------------------------------------------- video
    // The official hdmi_frame: the core's 14 MHz pixels into a line buffer,
    // out at 27 MHz with CEA 576p50 or 480p60 timing (the official top's
    // numbers).
    wire        hdmi_blank, hdmi_hsync_n, hdmi_vsync_n;
    wire [8:0]  hdmi_rgb;
    // video_60 (NextREG 05 bit 2) is a clock_28 signal; two registers bring it
    // into the pixel clock's domain before it picks the timing numbers below.
    reg  [1:0]  video_60_sync = 2'b00;
    reg         video_60 = 1'b0;
    always @(posedge pixel_clock) begin
        video_60_sync <= {video_60_sync[0], core_video_60};
        video_60 <= video_60_sync[1];
    end
    wire        video_60_change = video_60 != video_60_sync[1];
    // G_RELOCK: the pixel clock comes from the crystal, 24/25 of the machine
    // clock, so it cannot match the core's frame; re-lock every frame
    // (tests/sim/video/tb_hdmi_frame_relock.vhd: without it the picture drifts
    // through the line buffer within a few frames).
    // hdmi_frame's reset leaves on a pixel clock edge. machine_reset is a
    // clock_28 signal and the two clocks are asynchronous, so released straight
    // into hdmi_frame (until 2026-11-13) its registers could leave reset on
    // different pixel edges, a path no timing check covers. machine_reset
    // follows only the PLL lock and the SDRAM's start-up; the Next's soft and
    // hard resets (core_reset) never reach the video, so anything this reset
    // leaves wrong stays wrong until the next load.
    // A 50/60 Hz change also restarts the frame: the counters may be past the
    // new last line. (The core's own HDMI reset, core_hdmi_reset, also fires
    // on machine timing changes, which the re-lock follows without a restart.)
    wire frame_reset_async = !video_pll_lock || machine_reset;
    reg [2:0] frame_reset_sync = 3'b111;
    always @(posedge pixel_clock or posedge frame_reset_async)
        if (frame_reset_async) frame_reset_sync <= 3'b111;
        else if (video_60_change) frame_reset_sync <= 3'b111;
        else frame_reset_sync <= {frame_reset_sync[1:0], 1'b0};
    hdmi_frame #(.G_RELOCK(1)) frame (
        .i_reset_async_n(!frame_reset_sync[2]),
        .i_scanlines(2'b00),
        .i_CLK_RGB(clock_14), .i_CLK_RGB_EN(core_hdmi_pixel),
        .i_rgb_sync(core_hdmi_lock), .i_rgb(core_rgb),
        .i_CLK_HDMI(pixel_clock),
        .o_blank(hdmi_blank), .o_vsync_n(hdmi_vsync_n), .o_hsync_n(hdmi_hsync_n), .o_rgb(hdmi_rgb),
        .i_HACTIVE(video_60 ? 10'd138 : 10'd144),
        .i_HSYNC_BEG(video_60 ? 10'd16 : 10'd12),
        .i_HSYNC_END(video_60 ? 10'd77 : 10'd75),
        .i_HLAST(video_60 ? 10'd857 : 10'd863),
        .i_VACTIVE(video_60 ? 10'd45 : 10'd49),
        .i_VSYNC_BEG(video_60 ? 10'd9 : 10'd5),
        .i_VSYNC_END(video_60 ? 10'd14 : 10'd9),
        .i_VLAST(video_60 ? 10'd524 : 10'd624)
    );
    reg [2:0] pixel_reset_sync = 3'b111;
    always @(posedge pixel_clock or negedge video_pll_lock)
        if (!video_pll_lock) pixel_reset_sync <= 3'b111;
        else pixel_reset_sync <= {pixel_reset_sync[1:0], 1'b0};
    wire pixel_reset = pixel_reset_sync[2];
    wire [9:0] symbol_blue, symbol_green, symbol_red;
    generate
    if (AUDIO % 2 == 1) begin : hdmi_with_sound
        // HDMI with the core's sound in a data island on every line
        // (nexttang_hdmi_audio_out), the picture and its timing still
        // hdmi_frame's. 48 kHz samples against the 27 MHz pixel clock,
        // 48000 / 27e6 * 2^32, which the audio clock regeneration packets
        // announce (N 6144, CTS 27000).
        // Hardware (2026-11-12): NextBASIC BEEP 1,0 recorded by the Elgato at
        // 264 Hz, scales clean; 10 of 10 boots.
        wire hdmi_audio_ce;
        wire signed [15:0] hdmi_left, hdmi_right;
        nexttang_zxnext_audio_pcm #(.PHASE_INCREMENT(32'd7635497)) hdmi_audio_pcm (
            .core_clock(clock_28), .core_left(core_audio_left), .core_right(core_audio_right),
            .clock(pixel_clock), .reset(pixel_reset), .audio_ce(hdmi_audio_ce),
            .left(hdmi_left), .right(hdmi_right));
        nexttang_hdmi_audio_out #(.VIDEO_RATE(27.0E6), .AUDIO_RATE(48000)) hdmi_out (
            .clock(pixel_clock), .reset(pixel_reset), .video_60(video_60),
            .hactive(video_60 ? 10'd138 : 10'd144),
            .hsync_beg(video_60 ? 10'd16 : 10'd12),
            .hlast(video_60 ? 10'd857 : 10'd863),
            .vactive(video_60 ? 10'd45 : 10'd49),
            .vsync_end(video_60 ? 10'd14 : 10'd9),
            .vlast(video_60 ? 10'd524 : 10'd624),
            .blank(hdmi_blank), .hsync_n(hdmi_hsync_n), .vsync_n(hdmi_vsync_n), .rgb(hdmi_rgb),
            .audio_ce(hdmi_audio_ce), .audio_left(hdmi_left), .audio_right(hdmi_right),
            .symbol_blue(symbol_blue), .symbol_green(symbol_green), .symbol_red(symbol_red),
            .islands_locked());
    end else begin : dvi
        nexttang_tmds_encoder encode_blue (.pixel_clk(pixel_clock), .reset(pixel_reset),
            .video_data({hdmi_rgb[2:0], hdmi_rgb[2:0], hdmi_rgb[2:1]}),
            .control_zero(hdmi_hsync_n), .control_one(hdmi_vsync_n), .data_enable(!hdmi_blank), .symbol(symbol_blue));
        nexttang_tmds_encoder encode_green (.pixel_clk(pixel_clock), .reset(pixel_reset),
            .video_data({hdmi_rgb[5:3], hdmi_rgb[5:3], hdmi_rgb[5:4]}),
            .control_zero(1'b0), .control_one(1'b0), .data_enable(!hdmi_blank), .symbol(symbol_green));
        nexttang_tmds_encoder encode_red (.pixel_clk(pixel_clock), .reset(pixel_reset),
            .video_data({hdmi_rgb[8:6], hdmi_rgb[8:6], hdmi_rgb[8:7]}),
            .control_zero(1'b0), .control_one(1'b0), .data_enable(!hdmi_blank), .symbol(symbol_red));
    end
    endgenerate
    // The serializers share the pixel divider's reset, the video PLL's lock, as
    // Gowin's own DVI transmitter wires them (OSER10 RESET = ~rst_n with CLKDIV
    // RESETN = rst_n = pll_lock & key), so the divider and the serializers'
    // word counters start together. Released from pixel_reset (until 3f7950b)
    // they missed recovery against the 135 MHz clock by about 0.5 ns in every
    // build; with no reset at all (3f7950b to 1a5ea94) their start was left to
    // placement. Some loads of 1a5ea94 came up with a black HDMI picture while
    // NextZXOS ran (2 of 32, 2026-11-12), but this reset alone did not cure
    // that (1 to 3 black in about 25 loads, 2026-11-13); with hdmi_frame's
    // synchronised reset as well, 0 of 39. Which change cured it is not
    // isolated.
    wire serializer_reset = !video_pll_lock;
    wire [2:0] serial_data;
    OSER10 serialize_blue (.D0(symbol_blue[0]), .D1(symbol_blue[1]), .D2(symbol_blue[2]), .D3(symbol_blue[3]),
        .D4(symbol_blue[4]), .D5(symbol_blue[5]), .D6(symbol_blue[6]), .D7(symbol_blue[7]), .D8(symbol_blue[8]),
        .D9(symbol_blue[9]), .PCLK(pixel_clock), .FCLK(serial_clock), .RESET(serializer_reset), .Q(serial_data[0]));
    OSER10 serialize_green (.D0(symbol_green[0]), .D1(symbol_green[1]), .D2(symbol_green[2]), .D3(symbol_green[3]),
        .D4(symbol_green[4]), .D5(symbol_green[5]), .D6(symbol_green[6]), .D7(symbol_green[7]), .D8(symbol_green[8]),
        .D9(symbol_green[9]), .PCLK(pixel_clock), .FCLK(serial_clock), .RESET(serializer_reset), .Q(serial_data[1]));
    OSER10 serialize_red (.D0(symbol_red[0]), .D1(symbol_red[1]), .D2(symbol_red[2]), .D3(symbol_red[3]),
        .D4(symbol_red[4]), .D5(symbol_red[5]), .D6(symbol_red[6]), .D7(symbol_red[7]), .D8(symbol_red[8]),
        .D9(symbol_red[9]), .PCLK(pixel_clock), .FCLK(serial_clock), .RESET(serializer_reset), .Q(serial_data[2]));
    // The TMDS clock leaves through a fourth serializer (five ones, five
    // zeros per pixel), so it takes the same path to its pin as the data, and
    // all four pairs use the true LVDS buffers at LVDS25 3.5 mA, both as in
    // Gowin's DVI transmitter. Until 2026-11-13 the pixel clock went straight
    // from the divider to an emulated-LVDS buffer.
    wire serial_clock_out;
    OSER10 serialize_clock (.D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0), .D4(1'b0),
        .D5(1'b1), .D6(1'b1), .D7(1'b1), .D8(1'b1), .D9(1'b1),
        .PCLK(pixel_clock), .FCLK(serial_clock), .RESET(serializer_reset), .Q(serial_clock_out));
    TLVDS_OBUF tmds_clock_out (.I(serial_clock_out), .O(tmds_clk_p), .OB(tmds_clk_n));
    TLVDS_OBUF tmds_out_0 (.I(serial_data[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF tmds_out_1 (.I(serial_data[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF tmds_out_2 (.I(serial_data[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));

    // ------------------------------------------------------- other pins
    // SD on the core's SPI, as the official board drives it (zxnext_top_issue4):
    // SCK and MOSI registered on the rising edge of the CPU clock, chip select
    // and MISO direct (MISO unregistered leaves the card more time to answer).
    // On paper this leaves the card only 5 to 6 ns here (the core samples MISO
    // one 28 MHz cycle after it drops SCK, and the Nano's pin paths are slower
    // than the Spartan-6's); driving SCK and MOSI straight from the core's
    // registers would leave about 20 ns. Tried on 2026-11-11/12, the direct
    // drive booted worse, but those builds also had the SDRAM clock-crossing
    // fault fixed later that night, so the comparison is not conclusive. With
    // the crossings fixed, this official drive booted 10 of 10 and 15 of 15 on
    // Jon's card. Worth measuring on the pins before changing.
    reg sd_clk_q = 1'b0, sd_mosi_q = 1'b0;
    always @(posedge clock_28) begin
        sd_clk_q <= spi_clock;
        sd_mosi_q <= spi_mosi;
    end
    assign sd_clk = sd_clk_q;
    assign sd_mosi = sd_mosi_q;
    assign sd_cs = spi_sd0_select_n;
    assign sd_dat1 = 1'b1;
    assign sd_dat2 = 1'b1;

    assign debug_uart_tx = uart_tx;
    assign companion_irq_n = companion_seen ? 1'b1 : uart_tx;   // BL616 serial RX (debugger firmware); Companion IRQ idle
    // ------------------------------------------------------------- audio
    // AUDIO bit 1: the core's mixed stereo to the on-board MAX98357A over I2S: signed,
    // DC removed (nexttang_zxnext_audio_pcm, one sample per I2S frame:
    // 2^32 / 576), 48.828 kHz frames from a 28.125 MHz / 18 bit clock.
    // Using the core's audio output keeps its whole sound hardware
    // (TurboSound's three AYs, DACs, mixer), about 1,700 logic cells; with the
    // status line as well the Nano reached 89 percent and missed 28 MHz by
    // 8 ns (2026-11-11), so AUDIO goes with STATUS_LINE 0. HDMI and the
    // amplifier share that sound hardware.
    // (2026-11-12) Sound builds that met timing still failed to boot until
    // the SDRAM clock crossings were timed against the real clock phase
    // (nexttang_sdr_sdram_service.v, nano20k_zxnext.sdc); with that, the
    // amplifier build and the HDMI build each booted 10 of 10.
    generate
    if (AUDIO / 2 % 2 == 1) begin : amplifier
        wire signed [15:0] pcm_left, pcm_right;
        nexttang_zxnext_audio_pcm #(.PHASE_INCREMENT(32'd7456540)) audio_pcm (
            .core_clock(clock_28), .core_left(core_audio_left), .core_right(core_audio_right),
            .clock(clock_28), .reset(machine_reset), .audio_ce(),
            .left(pcm_left), .right(pcm_right));
        nexttang_i2s_transmitter #(.BCLK_HALF(9)) i2s (
            .clock(clock_28), .reset(machine_reset), .left(pcm_left), .right(pcm_right),
            .bclk(amp_bclk), .lrclk(amp_lrck), .data(amp_data));
        assign amp_enable = 1'b1;
    end else begin : no_amplifier
        assign amp_enable = 1'b0;
        assign amp_data = 1'b0;
        assign amp_lrck = 1'b0;
        assign amp_bclk = 1'b0;
    end
    endgenerate

    // LEDs, lit when driven low (to be confirmed on the board with the
    // bring-up image): 0 machine PLL, 1 SDRAM ready, 2 machine running,
    // 3 video PLL, 4 heartbeat, 5 SDRAM timeout.
    reg [24:0] heartbeat = 25'd0;
    always @(posedge clock_28) heartbeat <= heartbeat + 25'd1;
    assign led = ~{memory_timeout, heartbeat[24], video_pll_lock, !machine_reset, memory_ready, machine_pll_lock};
endmodule

`default_nettype wire
