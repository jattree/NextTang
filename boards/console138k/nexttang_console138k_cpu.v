// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// First hardware bring-up of the machine CPU.
//
// This deliberately does not draw anything. It answers two questions that have
// to be settled before a larger top is worth building: whether the Gowin flow
// accepts the VHDL CPU and boot ROM alongside the project's Verilog, and what
// the T80 core actually costs on this device. Both are cheaper to learn from a
// small build than from one that also carries video and memory.
//
// The processor runs the project's diagnostic firmware from block RAM at
// 3.5 MHz, with its screen and work memory in block RAM too, and reports over
// the status UART. Nothing here depends on DDR3 or on the video path.

`default_nettype none

module nexttang_console138k_cpu (
    input  wire       sys_clk,
    output wire       debug_uart_tx,
    output wire [4:0] probe
);
    // ---------------------------------------------------------------- clocks
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

    reg [3:0] reset_shift = 0;
    wire reset = !reset_shift[3];

    always @(posedge clock_28 or negedge machine_pll_locked) begin
        if (!machine_pll_locked)
            reset_shift <= 0;
        else
            reset_shift <= {reset_shift[2:0], 1'b1};
    end

    // The Z80 runs at 3.5 MHz, which is 28 MHz divided by eight. Using a clock
    // enable rather than a divided clock keeps everything in one clock domain,
    // so there is no crossing between the CPU and the memory it talks to.
    // T80Na drives the bus on both edges of its clock and does not consult the
    // core's clock enable, so the CPU needs a real 3.5 MHz clock rather than
    // being stepped by an enable.
    //
    // That clock comes from the CLKDIV primitive rather than a counter bit.
    // A fabric register driving a clock lands on general routing: the divider
    // measured a 34.8 ns delay to its own input, which is most of a 28 MHz
    // period spent getting the clock to where it is used.
    wire cpu_clock;

    CLKDIV #(.DIV_MODE("8")) cpu_clock_divider (
        .HCLKIN(clock_28),
        .RESETN(machine_pll_locked),
        .CALIB(1'b0),
        .CLKOUT(cpu_clock)
    );

    // ------------------------------------------------------------------- CPU
    wire [15:0] cpu_address;
    wire [7:0]  cpu_data_out;
    reg  [7:0]  cpu_data_in;
    wire mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n;

    T80Na #(.Mode(0)) cpu (
        .RESET_n(!reset),
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

    // ---------------------------------------------------------------- memory
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

    // The project's dual-port RAM rather than inferred arrays. Inference gave
    // a read-during-write mode this device's block RAM does not implement, and
    // port B is needed later anyway so the display can read screen memory
    // without stealing cycles from the processor.
    wire [7:0] screen_read;
    wire [7:0] work_read;

    nexttang_block_ram #(.ADDRESS_BITS(13)) screen_memory (
        .clock(cpu_clock),
        .write_enable(memory_write && in_screen),
        .write_address(cpu_address[12:0]),
        .write_data(cpu_data_out),
        .read_data(screen_read),
        .port_b_clock(cpu_clock),
        .port_b_address(13'b0),
        .port_b_data()
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

    // ------------------------------------------------------------ reporting
    // Sticky evidence that the processor is doing the things only correct
    // execution produces, readable when there is no picture to look at.
    reg opcode_seen = 0;
    reg screen_write_seen = 0;
    reg work_write_seen = 0;
    reg io_write_seen = 0;
    reg [31:0] opcode_count = 0;

    always @(posedge cpu_clock) begin
        if (reset) begin
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
        .reset(reset),
        .flags({!halt_n, io_write_seen, work_write_seen,
                screen_write_seen, opcode_seen, machine_pll_locked}),
        .value(opcode_count),
        .transmit(debug_uart_tx)
    );

    assign probe = {cpu_clock, m1_n, mreq_n, rd_n, wr_n};
endmodule

`default_nettype wire
