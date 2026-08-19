// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A 48K ZX Spectrum: the Z80 running a machine ROM against 48K of RAM, with
// its screen drawn to HDMI.
//
// This is the smallest workload that exercises the pieces the Next needs
// anyway. Booting a real ROM proves the processor, the memory map, the frame
// interrupt and the display path together, in a way no diagnostic firmware of
// our own can: the ROM was written against hardware, not against us.
//
// The ROM image is named by the build and is not part of this repository.
//
// What this is not: it does not implement contention, the floating bus, or the
// original video timing. The upstream core's zxula does all of that and is the
// intended destination. Nothing here duplicates it, because the display path is
// ours regardless and everything else is what any Spectrum needs.

`default_nettype none

`ifndef NEXTTANG_SPECTRUM48_TOP
`define NEXTTANG_SPECTRUM48_TOP nexttang_console138k_spectrum48
`endif

module `NEXTTANG_SPECTRUM48_TOP #(
    // The build writes the image into its own directory and runs there.
    parameter ROM_IMAGE = "48k.mem"
) (
    input  wire       sys_clk,
    output wire       debug_uart_tx,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire       tmds_psv,

    // Z80 bus brought out to PMOD1 for a logic analyser. Passive: nothing in
    // the machine depends on these.
    output wire [5:0] probe
`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    ,
    output wire        status_led,
    output wire        debug_uart_tx_alt,
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
    wire clock_14;
    wire clock_7;
    wire machine_pll_locked;

    nexttang_console138k_machine_pll machine_pll (
        .clock_in(sys_clk),
        .clock_28(clock_28),
        .clock_28_n(),
        .clock_14(clock_14),
        .clock_7(clock_7),
        .locked(machine_pll_locked)
    );

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    wire memory_clock;
    wire memory_reference_clock;
    wire memory_pll_locked;
    wire memory_clock_enable;
    wire controller_clock;
    wire controller_clock_enable;
    reg [7:0] controller_reset_shift = 0;
    wire controller_reset_n = controller_reset_shift[7];
    wire calibration_complete;
    wire ddr_reset;

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
`endif

    wire cpu_clock;

    CLKDIV #(.DIV_MODE("8")) cpu_clock_divider (
        .HCLKIN(clock_28),
        .RESETN(machine_pll_locked),
        .CALIB(1'b0),
        .CLKOUT(cpu_clock)
    );

    reg [3:0] pixel_reset_shift = 0;
    reg [3:0] cpu_reset_shift = 0;
    wire pixel_reset = !pixel_reset_shift[3];
`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    reg memory_available_meta = 0;
    reg memory_available_cpu = 0;
    wire cpu_reset = !cpu_reset_shift[3] || !memory_available_cpu;
`else
    wire cpu_reset = !cpu_reset_shift[3];
`endif

    always @(posedge pixel_clock or negedge video_pll_locked) begin
        if (!video_pll_locked)
            pixel_reset_shift <= 0;
        else
            pixel_reset_shift <= {pixel_reset_shift[2:0], 1'b1};
    end

    always @(posedge cpu_clock or negedge machine_pll_locked) begin
        if (!machine_pll_locked)
            cpu_reset_shift <= 0;
        else
            cpu_reset_shift <= {cpu_reset_shift[2:0], 1'b1};
    end

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    always @(posedge cpu_clock or negedge machine_pll_locked) begin
        if (!machine_pll_locked) begin
            memory_available_meta <= 1'b0;
            memory_available_cpu <= 1'b0;
        end else begin
            memory_available_meta <= calibration_complete;
            memory_available_cpu <= memory_available_meta;
        end
    end
`endif

    // -------------------------------------------------------------- interrupt
    // The ROM runs on interrupts: the keyboard scan, the frame counter and the
    // flash phase all hang off them, and without one it stops at the first
    // HALT. A 48K frame is 69888 processor cycles and the original hardware
    // held the line low for 32 of them.
    localparam integer FRAME_CYCLES = 69888;
    localparam integer INTERRUPT_CYCLES = 32;

    reg [16:0] frame_counter = 0;
    wire interrupt_n = !(frame_counter < INTERRUPT_CYCLES);

    always @(posedge cpu_clock) begin
        if (cpu_reset)
            frame_counter <= 0;
        else if (frame_counter == FRAME_CYCLES - 1)
            frame_counter <= 0;
        else
            frame_counter <= frame_counter + 1'b1;
    end

    // -------------------------------------------------------------------- CPU
    wire [15:0] cpu_address;
    wire [7:0]  cpu_data_out;
    reg  [7:0]  cpu_data_in;
    wire mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n;

    wire cpu_wait_n;

    T80Na #(.Mode(0)) cpu (
        .RESET_n(!cpu_reset),
        .CLK_n(cpu_clock),
        .WAIT_n(cpu_wait_n),
        .INT_n(interrupt_n),
        .NMI_n(1'b1),
        .BUSRQ_n(1'b1),
        .M1_n(m1_n),
        .MREQ_n(mreq_n),
        .IORQ_n(iorq_n),
        .RD_n(rd_n),
        .WR_n(wr_n),
        .RFSH_n(rfsh_n),
        .HALT_n(halt_n),
        .BUSAK_n(),
        .A(cpu_address),
        .D_i(cpu_data_in),
        .D_o(cpu_data_out),
        .Z80N_dout_o(),
        .Z80N_data_o(),
        .Z80N_command_o()
    );

    // ----------------------------------------------------------------- memory
    // ROM occupies the bottom 16K and RAM the rest. The RAM is addressed by the
    // full processor address so the display can read the screen at its real
    // address, and its bottom 16K is simply never used.
    wire in_rom = (cpu_address[15:14] == 2'b00);
    wire memory_write = !mreq_n && !wr_n && !in_rom;

    wire [7:0] rom_data;
    wire [7:0] ram_data;
    wire [12:0] display_address;
    wire [7:0]  display_data;
    wire [13:0] ula_vram_address;
    wire [7:0]  ula_vram_data;

    nexttang_rom #(
        .ADDRESS_BITS(14),
        .IMAGE(ROM_IMAGE)
    ) machine_rom (
        .clock(cpu_clock),
        .address(cpu_address[13:0]),
        .data(rom_data)
    );

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    wire upper_transaction_complete;
    wire line_request;
    wire line_ready;
    wire line_write;
    wire [16:0] line_address;
    wire [127:0] line_write_data;
    wire [15:0] line_write_enable;
    wire line_response_valid;
    wire [127:0] line_read_data;
    wire fault_timeout;
    wire fault_overrun;
    wire fault_calibration_lost;

    nexttang_spectrum48_split_memory machine_ram (
        .cpu_clock(cpu_clock),
        .cpu_reset(cpu_reset),
        .memory_available(memory_available_cpu),
        .cpu_address(cpu_address),
        .cpu_write_data(cpu_data_out),
        .cpu_mreq_n(mreq_n),
        .cpu_rd_n(rd_n),
        .cpu_wr_n(wr_n),
        .cpu_rfsh_n(rfsh_n),
        .ram_read_data(ram_data),
        .cpu_wait_n(cpu_wait_n),
        .upper_transaction_complete(upper_transaction_complete),
        .video_clock(clock_7),
        .video_address(ula_vram_address),
        .video_data(ula_vram_data),
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
    assign cpu_wait_n = 1'b1;

    nexttang_block_ram #(.ADDRESS_BITS(16)) machine_ram (
        .clock(cpu_clock),
        .write_enable(memory_write),
        .write_address(cpu_address),
        .write_data(cpu_data_out),
        .read_data(ram_data),
`ifdef NEXTTANG_SPECTRUM48_USE_ULA
        .port_b_clock(clock_7),
        .port_b_address({2'b01, ula_vram_address}),  // ULA screen bank at 0x4000
        .port_b_data(ula_vram_data)
`else
        .port_b_clock(pixel_clock),
        .port_b_address({3'b010, display_address}),  // screen lives at 0x4000
        .port_b_data(display_data)
`endif
    );
`endif

    // Port 0xFE is decoded on address bit 0 alone, as the original did. Reading
    // it returns the keyboard in the low five bits, with the tape input low.
    wire port_fe = !iorq_n && !cpu_address[0];

    wire [39:0] keys;
    wire [4:0] key_columns;
    wire typing_finished;

    nexttang_key_sequencer #(.CLOCK_HZ(3500000)) typist (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .keys(keys),
        .finished(typing_finished)
    );

    nexttang_keyboard_matrix keyboard (
        .row_select(cpu_address[15:8]),
        .keys(keys),
        .columns(key_columns)
    );
    reg [2:0] border_colour = 3'd0;

    always @(posedge cpu_clock) begin
        if (cpu_reset)
            border_colour <= 3'd0;
        else if (port_fe && !wr_n)
            border_colour <= cpu_data_out[2:0];
    end

    always @(*) begin
        if (!iorq_n)
            cpu_data_in = port_fe ? {1'b1, 1'b0, 1'b1, key_columns} : 8'hff;
        else if (in_rom)
            cpu_data_in = rom_data;
        else
            cpu_data_in = ram_data;
    end

    reg [2:0] border_meta = 3'd0;
    reg [2:0] border_pixel = 3'd0;

    always @(posedge pixel_clock) begin
        border_meta  <= border_colour;
        border_pixel <= border_meta;
    end

    // ------------------------------------------------------------------ video
    wire timing_hsync;
    wire timing_vsync;
    wire timing_data_enable;
    wire [10:0] horizontal_position;
    wire [9:0]  vertical_position;

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
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;

`ifdef NEXTTANG_SPECTRUM48_USE_ULA
    // The imported timing and ULA modules generate the native 48K raster.  A
    // frame buffer is the explicit 50 Hz -> 60 Hz clock and cadence boundary;
    // it doubles the qualified 360x288 source to 720x576 inside 720p.
    wire ula_frame_sync;
    wire ula_hdmi_pixel_enable;
    wire ula_hdmi_frame_lock;
    wire ula_hblank_n;
    wire ula_vblank_n;
    wire ula_hsync_n;
    wire ula_vsync_n;
    wire [8:0] ula_hc;
    wire [8:0] ula_vc;
    wire [8:0] ula_cvc;
    wire [8:0] ula_whc;
    wire [8:0] ula_wvc;
    wire [8:0] ula_phc;
    wire [1:0] ula_subpixel;
    wire ula_interrupt;
    wire ula_line_interrupt;

    zxula_timing ula_timing (
        .i_CLK_28(clock_28),
        .i_50_60(1'b0),
        .i_timing(3'b000),
        .i_cu_offset(8'h00),
        .i_CLK_7(clock_7),
        .o_vblank_n(ula_vblank_n),
        .o_hblank_n(ula_hblank_n),
        .o_hsync_n(ula_hsync_n),
        .o_vsync_n(ula_vsync_n),
        .o_frame_sync(ula_frame_sync),
        .o_hdmi_pixel_en(ula_hdmi_pixel_enable),
        .o_hdmi_frame_lock(ula_hdmi_frame_lock),
        .o_hc_ula(ula_hc),
        .o_vc_ula(ula_vc),
        .o_vc_cu(ula_cvc),
        .o_whc(ula_whc),
        .o_wvc(ula_wvc),
        .o_phc(ula_phc),
        .center(1'b1),
        .o_sc(ula_subpixel),
        .i_inten_ula_n(1'b0),
        .i_inten_line(1'b0),
        .i_int_line(9'b0),
        .o_int_ula(ula_interrupt),
        .o_int_line(ula_line_interrupt)
    );

    wire ula_shadow;
    wire ula_vram_read;
    wire ula_border;
    wire [7:0] ula_pixel;
    wire ula_select_background;
    wire ula_clipped;
    wire [7:0] ula_floating_bus;
    wire ula_wait_n;
    wire ula_cpu_contend;

    zxula ula (
        .i_CLK_7(clock_7),
        .i_CLK_14(clock_14),
        .i_CLK_CPU(cpu_clock),
        .i_cpu_mreq_n(mreq_n),
        .i_cpu_iorq_n(iorq_n),
        .i_hc(ula_hc),
        .i_vc(ula_vc),
        .i_phc(ula_phc),
        .i_timing_pentagon(1'b0),
        .i_timing_p3(1'b0),
        .i_port_ff_reg(6'b0),
        .i_port_fe_border(border_colour),
        .i_ula_shadow_en(1'b0),
        .i_ulanext_en(1'b0),
        .i_ulanext_format(8'hff),
        .i_ulap_en(1'b0),
        .o_ula_vram_a(ula_vram_address),
        .o_ula_shadow(ula_shadow),
        .o_ula_vram_rd(ula_vram_read),
        .i_ula_vram_d(ula_vram_data),
        .o_ula_border(ula_border),
        .o_ula_pixel(ula_pixel),
        .o_ula_select_bgnd(ula_select_background),
        .o_ula_clipped(ula_clipped),
        .i_ula_clip_x1(8'h00),
        .i_ula_clip_x2(8'hff),
        .i_ula_clip_y1(8'h00),
        .i_ula_clip_y2(8'hbf),
        .i_ula_scroll_x(8'h00),
        .i_ula_scroll_y(8'h00),
        .i_ula_fine_scroll_x(1'b0),
        .i_p3_floating_bus(8'hff),
        .o_ula_floating_bus(ula_floating_bus),
        .i_contention_en(1'b0),
        .i_contention_port(1'b0),
        .i_contention_memory(1'b0),
        .o_cpu_wait_n(ula_wait_n),
        .o_cpu_contend(ula_cpu_contend)
    );

    wire capture_frame_start;
    wire capture_pixel_valid;
    wire [8:0] capture_x;
    wire [8:0] capture_y;
    wire [7:0] capture_pixel;
    wire capture_protocol_error;

    nexttang_ula_capture capture (
        .clock(clock_7),
        .reset(!machine_pll_locked),
        .frame_sync(ula_frame_sync),
        .pixel_valid(ula_hdmi_pixel_enable),
        .pixel(ula_pixel),
        .capture_frame_start(capture_frame_start),
        .capture_pixel_valid(capture_pixel_valid),
        .capture_x(capture_x),
        .capture_y(capture_y),
        .capture_pixel(capture_pixel),
        .protocol_error(capture_protocol_error)
    );

    wire scaled_frame_valid;
    wire scaled_overrun;
    wire [7:0] scaled_pixel;
    wire output_frame_start = horizontal_position == 0 && vertical_position == 0;

    nexttang_framebuffer_scaler scaler (
        .source_clock(clock_7),
        .source_reset(!machine_pll_locked),
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

    nexttang_ula_palette palette (
        .palette_index(scaled_pixel),
        .red(red),
        .green(green),
        .blue(blue)
    );
`else
    assign hsync = timing_hsync;
    assign vsync = timing_vsync;
    assign data_enable = timing_data_enable;

    reg previous_vsync = 0;
    reg [4:0] flash_counter = 0;

    always @(posedge pixel_clock) begin
        if (pixel_reset) begin
            previous_vsync <= 0;
            flash_counter <= 0;
        end else begin
            previous_vsync <= vsync;
            if (vsync && !previous_vsync)
                flash_counter <= flash_counter + 1'b1;
        end
    end

    nexttang_spectrum_display #(.SCALE(3)) display (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position),
        .data_enable(data_enable),
        .border_colour(border_pixel),
        .flash_phase(flash_counter[4]),
        .screen_address(display_address),
        .screen_data(display_data),
        .red(red),
        .green(green),
        .blue(blue)
    );
`endif

    wire [9:0] red_symbol;
    wire [9:0] green_symbol;
    wire [9:0] blue_symbol;
    wire [2:0] serial_data;

    nexttang_tmds_encoder blue_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(blue), .control_zero(hsync), .control_one(vsync),
        .data_enable(data_enable), .symbol(blue_symbol)
    );
    nexttang_tmds_encoder green_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(green), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(green_symbol)
    );
    nexttang_tmds_encoder red_encoder (
        .pixel_clk(pixel_clock), .reset(pixel_reset),
        .video_data(red), .control_zero(1'b0), .control_one(1'b0),
        .data_enable(data_enable), .symbol(red_symbol)
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
    // The flags say how far the ROM got. Reaching the first HALT means it
    // finished its memory sizing and set up its screen, which is the point past
    // which a picture is expected.
    reg opcode_seen = 0;
    reg screen_write_seen = 0;
    reg high_ram_write_seen = 0;
    reg border_write_seen = 0;
    reg halt_seen = 0;
    reg [31:0] opcode_count = 0;

    always @(posedge cpu_clock) begin
        if (cpu_reset) begin
            opcode_seen <= 0;
            screen_write_seen <= 0;
            high_ram_write_seen <= 0;
            border_write_seen <= 0;
            halt_seen <= 0;
            opcode_count <= 0;
        end else begin
            if (!m1_n && !mreq_n && rfsh_n) begin
                opcode_seen <= 1'b1;
                opcode_count <= opcode_count + 1'b1;
            end
            if (memory_write && cpu_address[15:11] == 5'b01000)
                screen_write_seen <= 1'b1;
            if (memory_write && cpu_address[15])
                high_ram_write_seen <= 1'b1;
            if (port_fe && !wr_n)
                border_write_seen <= 1'b1;
            if (!halt_n)
                halt_seen <= 1'b1;
        end
    end

    // Slow enough for a 24 MHz analyser and chosen to show the machine's
    // rhythm: opcode fetches, memory against IO, writes, and the 50 Hz frame
    // interrupt the ROM runs on.
    assign probe = {interrupt_n, wr_n, iorq_n, mreq_n, m1_n, cpu_clock};

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    wire [5:0] status_flags = {
        fault_calibration_lost, fault_overrun, fault_timeout,
        calibration_complete, high_ram_write_seen, opcode_seen
    };
`elsif NEXTTANG_SPECTRUM48_USE_ULA
    wire [5:0] status_flags = {
        capture_protocol_error, scaled_overrun, scaled_frame_valid,
        screen_write_seen, opcode_seen, video_pll_locked
    };
`else
    wire [5:0] status_flags = {
        typing_finished, border_write_seen, high_ram_write_seen,
        screen_write_seen, opcode_seen, video_pll_locked
    };
`endif

    nexttang_debug_status_uart #(
        .CLOCK_HZ(3500000)
    ) status_uart (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .flags(status_flags),
        .value(opcode_count),
        .transmit(debug_uart_tx)
    );

`ifdef NEXTTANG_SPECTRUM48_USE_DDR3
    assign debug_uart_tx_alt = debug_uart_tx;
    assign status_led = calibration_complete &&
                        !fault_timeout && !fault_overrun &&
                        !fault_calibration_lost ? 1'b0 : 1'b1;
`endif
endmodule

`default_nettype wire
