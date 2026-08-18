// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// The processor and the display together: a Z80 running the diagnostic
// firmware out of block RAM, with its screen memory drawn to HDMI.
//
// This is the first image where the machine is visible rather than inferred
// from a UART line. The firmware fills the screen through the Spectrum's
// interleaved layout, tests its work memory, then cycles attributes, so a
// correct picture is evidence the processor executed, addressed memory and
// wrote the bytes the display is reading.
//
// The two halves run at their own rates. The processor and its memory sit in a
// 3.5 MHz domain; video runs at 74.375 MHz for 720p60. Screen memory is the
// only thing they share, through the read port the display owns.

`default_nettype none

module nexttang_console138k_spectrum (
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
    wire machine_pll_locked;

    nexttang_console138k_machine_pll machine_pll (
        .clock_in(sys_clk),
        .clock_28(clock_28),
        .clock_28_n(),
        .clock_14(),
        .clock_7(),
        .locked(machine_pll_locked)
    );

    // T80Na drives the bus on both edges of its clock and does not consult the
    // core's clock enable, so it needs a real divided clock. CLKDIV rather than
    // a counter bit: a fabric register driving a clock lands on general routing.
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
    wire cpu_reset = !cpu_reset_shift[3];

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

    // -------------------------------------------------------------------- CPU
    wire [15:0] cpu_address;
    wire [7:0]  cpu_data_out;
    reg  [7:0]  cpu_data_in;
    wire mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n;

    T80Na #(.Mode(0)) cpu (
        .RESET_n(!cpu_reset),
        .CLK_n(cpu_clock),
        .WAIT_n(1'b1),
        .INT_n(1'b1),
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
    wire [7:0] rom_data;

    bootrom boot_rom (
        .CLK(cpu_clock),
        .ADDR(cpu_address[12:0]),
        .DATA(rom_data)
    );

    wire in_screen = (cpu_address[15:14] == 2'b01);          // 0x4000 window
    wire in_work   = (cpu_address[15:14] == 2'b10);          // 0x8000 window
    wire in_rom    = (cpu_address[15:13] == 3'b000);         // 0x0000 window
    wire memory_write = !mreq_n && !wr_n;

    wire [7:0] screen_read;
    wire [7:0] work_read;
    wire [12:0] display_address;
    wire [7:0]  display_data;

    nexttang_block_ram #(.ADDRESS_BITS(13)) screen_memory (
        .clock(cpu_clock),
        .write_enable(memory_write && in_screen),
        .write_address(cpu_address[12:0]),
        .write_data(cpu_data_out),
        .read_data(screen_read),
        .port_b_clock(pixel_clock),
        .port_b_address(display_address),
        .port_b_data(display_data)
    );

    nexttang_block_ram #(.ADDRESS_BITS(14)) work_memory (
        .clock(cpu_clock),
        .write_enable(memory_write && in_work),
        .write_address(cpu_address[13:0]),
        .write_data(cpu_data_out),
        .read_data(work_read),
        .port_b_clock(cpu_clock),
        .port_b_address(14'b0),
        .port_b_data()
    );

    always @(*) begin
        if (in_screen)
            cpu_data_in = screen_read;
        else if (in_work)
            cpu_data_in = work_read;
        else if (in_rom)
            cpu_data_in = rom_data;
        else
            cpu_data_in = 8'hff;
    end

    // The border, as the machine set it. Port 0xFE carries it in the low three
    // bits, and the firmware writes it on entry and again if memory fails.
    reg [2:0] border_colour = 3'd0;

    always @(posedge cpu_clock) begin
        if (cpu_reset)
            border_colour <= 3'd0;
        else if (!iorq_n && !wr_n && !cpu_address[0])
            border_colour <= cpu_data_out[2:0];
    end

    // Crossing into the pixel domain. Two stages, because the value changes on
    // a clock the video side knows nothing about. A frame drawn with a torn
    // border would be harmless, but a metastable one is not.
    reg [2:0] border_meta = 3'd0;
    reg [2:0] border_pixel = 3'd0;

    always @(posedge pixel_clock) begin
        border_meta  <= border_colour;
        border_pixel <= border_meta;
    end

    // ------------------------------------------------------------------ video
    wire hsync;
    wire vsync;
    wire data_enable;
    wire [10:0] horizontal_position;
    wire [9:0]  vertical_position;

    nexttang_video_timing timing (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .hsync(hsync),
        .vsync(vsync),
        .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    // Flash swaps ink and paper twice a second, which the original machine took
    // from bit 4 of a frame counter. At 60 Hz that is every 16 frames.
    reg previous_vsync = 0;
    reg [4:0] frame_counter = 0;

    always @(posedge pixel_clock) begin
        if (pixel_reset) begin
            previous_vsync <= 0;
            frame_counter <= 0;
        end else begin
            previous_vsync <= vsync;
            if (vsync && !previous_vsync)
                frame_counter <= frame_counter + 1'b1;
        end
    end

    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;

    nexttang_spectrum_display #(.SCALE(3)) display (
        .pixel_clk(pixel_clock),
        .reset(pixel_reset),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position),
        .data_enable(data_enable),
        .border_colour(border_pixel),
        .flash_phase(frame_counter[4]),
        .screen_address(display_address),
        .screen_data(display_data),
        .red(red),
        .green(green),
        .blue(blue)
    );

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

    // The HDMI connector's source-side 5V presence line. Sipeed report this has
    // to be driven high for the output to be recognised; every image this
    // project has built so far left it floating.
    assign tmds_psv = 1'b1;

    // --------------------------------------------------------------- reporting
    reg opcode_seen = 0;
    reg screen_write_seen = 0;
    reg work_write_seen = 0;
    reg io_write_seen = 0;
    reg [31:0] opcode_count = 0;

    always @(posedge cpu_clock) begin
        if (cpu_reset) begin
            opcode_seen <= 0;
            screen_write_seen <= 0;
            work_write_seen <= 0;
            io_write_seen <= 0;
            opcode_count <= 0;
        end else begin
            if (!m1_n && !mreq_n && rfsh_n) begin
                opcode_seen <= 1'b1;
                opcode_count <= opcode_count + 1'b1;
            end
            if (memory_write && in_screen)
                screen_write_seen <= 1'b1;
            if (memory_write && in_work)
                work_write_seen <= 1'b1;
            if (!iorq_n && !wr_n)
                io_write_seen <= 1'b1;
        end
    end

    nexttang_debug_status_uart #(
        .CLOCK_HZ(3500000)
    ) status_uart (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .flags({!halt_n, io_write_seen, work_write_seen,
                screen_write_seen, opcode_seen, video_pll_locked}),
        .value(opcode_count),
        .transmit(debug_uart_tx)
    );
endmodule

`default_nettype wire
