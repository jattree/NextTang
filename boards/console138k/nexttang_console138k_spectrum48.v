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

module nexttang_console138k_spectrum48 #(
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
);
    // ----------------------------------------------------------------- clocks
    wire serial_clock;
    wire pixel_clock;
    wire video_pll_locked;

    nexttang_console138k_pll video_pll (
        .clock_in(sys_clk),
        .serial_clock(serial_clock),
        .locked(video_pll_locked)
    );

    CLKDIV #(.DIV_MODE(5)) pixel_clock_divider (
        .HCLKIN(serial_clock),
        .RESETN(video_pll_locked),
        .CALIB(1'b0),
        .CLKOUT(pixel_clock)
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

    T80Na #(.Mode(0)) cpu (
        .RESET_n(!cpu_reset),
        .CLK_n(cpu_clock),
        .WAIT_n(1'b1),
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

    nexttang_rom #(
        .ADDRESS_BITS(14),
        .IMAGE(ROM_IMAGE)
    ) machine_rom (
        .clock(cpu_clock),
        .address(cpu_address[13:0]),
        .data(rom_data)
    );

    nexttang_block_ram #(.ADDRESS_BITS(16)) machine_ram (
        .clock(cpu_clock),
        .write_enable(memory_write),
        .write_address(cpu_address),
        .write_data(cpu_data_out),
        .read_data(ram_data),
        .port_b_clock(pixel_clock),
        .port_b_address({3'b010, display_address}),   // screen lives at 0x4000
        .port_b_data(display_data)
    );

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
        .flash_phase(flash_counter[4]),
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

    nexttang_debug_status_uart #(
        .CLOCK_HZ(3500000)
    ) status_uart (
        .clock(cpu_clock),
        .reset(cpu_reset),
        .flags({typing_finished, border_write_seen, high_ram_write_seen,
                screen_write_seen, opcode_seen, video_pll_locked}),
        .value(opcode_count),
        .transmit(debug_uart_tx)
    );
endmodule

`default_nettype wire
