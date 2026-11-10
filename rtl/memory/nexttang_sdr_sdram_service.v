// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Main memory for boards with SDR SDRAM (first user: the Tang Nano 20K's
// in-package 2M x 32 die). Serves the machine's memory ports A and C
// (rtl/platform/nexttang_next_machine.v, "memory contract") and refreshes.
//
// Status: first version. Port B (Layer 2) is not served here yet; a board
// using this sets LAYER2_UNITS to zero, so the core shows Layer 2 as
// transparent. Layer 2 needs its own design (column-ordered modes read with
// a 256-byte stride; the deadline is four machine cycles), which comes next.
//
// Clocking. memory_clock runs at four times machine_clock and both come from
// one PLL (the Nano: 112.5 and 28.125 MHz), so a machine cycle is four memory
// cycles and the clocks are related: requests cross by toggles that the
// static timer checks, with no synchroniser latency. The SDRAM gets the
// inverted memory clock, so commands and write data sit mid-eye at its pins.
//
// Accesses. One 32-bit word per ACTIVE, READ or WRITE with auto-precharge,
// CAS latency 2, burst length 1; a byte write uses the DQM lanes. Each
// access occupies the bank for OP_CYCLES (tRC), refresh likewise. Read data
// is taken from the pins on the falling memory-clock edge CL + 1.5 cycles
// after READ, the middle of the data window at these speeds (the bring-up
// self-test's capture B checks exactly this point on the board).
//
// Ordering. One access at a time, in this order of priority: an overdue
// refresh, port A, port C, a due refresh. Port A is the CPU and DMA: wait is
// raised combinationally from the request and released when read data is
// ready or a write has reached the SDRAM. The core cannot start another port A
// cycle while wait is high, so there is never more than one outstanding.
// Port C is held until
// it is acknowledged with a one-machine-cycle pulse; read data is valid
// from the cycle after.
//
// Address map: the core's byte address [20:0] -> word [20:2], lane [1:0].
// Word address -> column [7:0], bank [9:8], row [20:10] (the top two row bits
// are zero: the Next's 2 MiB is a quarter of the die).

`default_nettype none

module nexttang_sdr_sdram_service #(
    parameter integer MEMORY_HZ    = 112_500_000,
    parameter integer TRCD         = 2,     // ACTIVE to READ/WRITE, cycles
    parameter integer OP_CYCLES    = 8,     // ACTIVE to next ACTIVE (tRC, tWR + tRP)
    parameter integer REFRESH_US10 = 78,    // refresh interval in 0.1 us (64 ms / 8192)
    parameter integer TIMEOUT      = 4096   // port A memory cycles before fault_timeout
) (
    input  wire        machine_clock,
    input  wire        memory_clock,
    input  wire        reset,           // memory domain, held until the PLL locks
    output reg         ready = 1'b0,    // initialised; the machine may leave reset

    // port A (machine_clock)
    input  wire        a_request,       // one-cycle pulse at the start of a memory cycle
    input  wire        a_cycle_request, // level for the whole cycle
    input  wire        a_read_n,
    input  wire [20:0] a_address,
    input  wire [7:0]  a_write_data,
    output wire [7:0]  a_read_data,
    output wire        a_wait,

    // port C (machine_clock)
    input  wire        c_request,
    input  wire        c_read_n,
    input  wire [20:0] c_address,
    input  wire [7:0]  c_write_data,
    output reg  [7:0]  c_read_data = 8'd0,
    output reg         c_ack = 1'b0,
    output wire        c_busy,

    output reg         fault_timeout = 1'b0,

    // SDRAM
    output wire        sdram_clk,
    output reg         sdram_cke = 1'b0,
    output reg         sdram_cs_n = 1'b1,
    output reg         sdram_ras_n = 1'b1,
    output reg         sdram_cas_n = 1'b1,
    output reg         sdram_we_n = 1'b1,
    output reg  [10:0] sdram_addr = 11'd0,
    output reg  [1:0]  sdram_ba = 2'd0,
    output reg  [3:0]  sdram_dqm = 4'hF,
    inout  wire [31:0] sdram_dq
);
    localparam integer CL = 2;
    localparam integer INIT_CYCLES    = MEMORY_HZ / 5000 + 64;           // 200 us
    localparam integer REFRESH_CYCLES = MEMORY_HZ / 10_000_000 * REFRESH_US10;

    assign sdram_clk = ~memory_clock;

    // ------------------------------------------------ machine-domain side
    // Port A: the request is captured at its pulse and handed over by toggle.
    reg        a_toggle = 1'b0;
    reg        a_op_read_n = 1'b0;
    reg [20:0] a_op_address = 21'd0;
    reg [7:0]  a_op_data = 8'd0;
    wire       a_done_toggle;           // memory domain
    wire [31:0] a_word;                 // memory domain, stable once done
    reg  [1:0] a_lane = 2'd0;
    wire       a_pending = a_toggle != a_done_toggle;
    // Raised in the request's own cycle, before the core can sample it, and
    // held while the access is outstanding.
    assign a_wait = a_cycle_request && (a_request || a_pending);
    always @(posedge machine_clock) begin
        if (a_request && !a_pending) begin
            a_toggle <= !a_toggle;
            a_op_read_n <= a_read_n;
            a_op_address <= a_address;
            a_op_data <= a_write_data;
            a_lane <= a_address[1:0];
        end
    end
    // Valid as soon as wait drops: a_word is a memory-domain register loaded
    // on the same edge that completes the access, and a_lane is held.
    assign a_read_data = a_word[8 * a_lane +: 8];
    // Port C: same handshake, acknowledged with a one-cycle pulse.
    reg        c_toggle = 1'b0;
    reg        c_op_read_n = 1'b0;
    reg [20:0] c_op_address = 21'd0;
    reg [7:0]  c_op_data = 8'd0;
    reg [1:0]  c_lane = 2'd0;
    wire       c_done_toggle;
    wire [31:0] c_word;
    reg        c_seen = 1'b0;
    reg        c_armed = 1'b1;          // the request has been low since the last ack
    wire       c_pending = c_toggle != c_done_toggle;
    assign c_busy = c_request || c_pending;
    always @(posedge machine_clock) begin
        c_ack <= 1'b0;
        if (!c_request) c_armed <= 1'b1;
        // The requester sees the ack a cycle late and still holds its request
        // in that cycle: only a request that has been low since the last ack
        // is a new one.
        if (c_request && c_armed && !c_pending && !c_seen) begin
            c_toggle <= !c_toggle; c_seen <= 1'b1; c_armed <= 1'b0;
            c_op_read_n <= c_read_n; c_op_address <= c_address; c_op_data <= c_write_data;
            c_lane <= c_address[1:0];
        end else if (c_seen && !c_pending) begin
            c_ack <= 1'b1; c_seen <= 1'b0;
            c_read_data <= c_word[8 * c_lane +: 8];
        end
    end

    // ------------------------------------------------- memory-domain side
    reg        a_seen_m = 1'b0, c_seen_m = 1'b0;
    reg        a_done_m = 1'b0, c_done_m = 1'b0;
    reg [31:0] a_word_m = 32'd0, c_word_m = 32'd0;
    assign a_done_toggle = a_done_m;
    assign a_word = a_word_m;
    assign c_done_toggle = c_done_m;
    assign c_word = c_word_m;

    reg        dq_oe = 1'b0;
    reg [31:0] dq_out = 32'd0;
    assign sdram_dq = dq_oe ? dq_out : 32'bz;
    reg [31:0] dq_fall = 32'd0;
    always @(negedge memory_clock) dq_fall <= sdram_dq;

    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

    localparam S_INIT = 3'd0, S_PRE = 3'd1, S_REF1 = 3'd2, S_REF2 = 3'd3, S_MRS = 3'd4,
               S_IDLE = 3'd5, S_OP = 3'd6;

    reg [2:0]  state = S_INIT;
    reg [15:0] count = 16'd0;
    reg [4:0]  step = 5'd0;           // cycles since ACTIVE (or REFRESH)
    reg [15:0] refresh_count = 16'd0;
    reg [1:0]  refresh_owed = 2'd0;
    reg        op_refresh = 1'b0, op_port_c = 1'b0, op_read = 1'b0;
    reg [20:0] op_address = 21'd0;
    reg [7:0]  op_data = 8'd0;
    reg [15:0] a_age = 16'd0;

    wire a_new = a_toggle != a_seen_m;
    wire c_new = c_toggle != c_seen_m;

    task automatic command(input [3:0] c);
        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= c;
    endtask

    always @(posedge memory_clock) begin
        command(C_NOP);
        dq_oe <= 1'b0;
        if (refresh_count != 16'd0) refresh_count <= refresh_count - 16'd1;
        else begin
            refresh_count <= REFRESH_CYCLES[15:0];
            if (refresh_owed != 2'd3) refresh_owed <= refresh_owed + 2'd1;
        end
        if (a_new && a_age != 16'hFFFF) a_age <= a_age + 16'd1;
        if (a_age == TIMEOUT[15:0] * 16'd4) fault_timeout <= 1'b1;

        if (reset) begin
            state <= S_INIT; count <= INIT_CYCLES[15:0]; sdram_cke <= 1'b0; ready <= 1'b0;
            sdram_dqm <= 4'hF; refresh_owed <= 2'd0; refresh_count <= REFRESH_CYCLES[15:0];
            a_seen_m <= a_toggle; a_done_m <= a_toggle; c_seen_m <= c_toggle; c_done_m <= c_toggle;
            fault_timeout <= 1'b0; a_age <= 16'd0;
        end else case (state)
            S_INIT: begin
                sdram_cke <= 1'b1;
                if (count != 16'd0) count <= count - 16'd1; else state <= S_PRE;
            end
            S_PRE: begin command(C_PRE); sdram_addr <= 11'h400; count <= 16'd4; state <= S_REF1; end
            S_REF1: if (count != 16'd0) count <= count - 16'd1;
                    else begin command(C_REF); count <= OP_CYCLES[15:0]; state <= S_REF2; end
            S_REF2: if (count != 16'd0) count <= count - 16'd1;
                    else begin command(C_REF); count <= OP_CYCLES[15:0]; state <= S_MRS; end
            S_MRS: if (count != 16'd0) count <= count - 16'd1;
                   else begin
                       command(C_MRS); sdram_ba <= 2'b00;
                       sdram_addr <= 11'b0000_010_0_000;    // burst write, CL 2, sequential, BL 1
                       count <= 16'd4; state <= S_IDLE;
                   end
            S_IDLE: begin
                if (count != 16'd0) count <= count - 16'd1;
                else begin
                    ready <= 1'b1;
                    step <= 5'd0;
                    if (refresh_owed >= 2'd2 || (refresh_owed != 2'd0 && !a_new && !c_new)) begin
                        command(C_REF); refresh_owed <= refresh_owed - 2'd1;
                        op_refresh <= 1'b1; state <= S_OP;
                    end else if (a_new) begin
                        a_seen_m <= a_toggle; a_age <= 16'd0;
                        op_refresh <= 1'b0; op_port_c <= 1'b0;
                        op_read <= !a_op_read_n; op_address <= a_op_address; op_data <= a_op_data;
                        command(C_ACT); sdram_ba <= a_op_address[11:10]; sdram_addr <= a_op_address[20:12] & 11'h1FF;
                        state <= S_OP;
                    end else if (c_new) begin
                        c_seen_m <= c_toggle;
                        op_refresh <= 1'b0; op_port_c <= 1'b1;
                        op_read <= !c_op_read_n; op_address <= c_op_address; op_data <= c_op_data;
                        command(C_ACT); sdram_ba <= c_op_address[11:10]; sdram_addr <= c_op_address[20:12] & 11'h1FF;
                        state <= S_OP;
                    end
                end
            end
            S_OP: begin
                step <= step + 5'd1;
                if (!op_refresh && step == TRCD[4:0] - 5'd1) begin
                    sdram_ba <= op_address[11:10];
                    sdram_addr <= {3'b100, op_address[9:2]};      // A10: auto-precharge
                    if (op_read) begin
                        command(C_READ); sdram_dqm <= 4'h0;
                    end else begin
                        command(C_WRITE); dq_oe <= 1'b1;
                        dq_out <= {4{op_data}};
                        sdram_dqm <= ~(4'b0001 << op_address[1:0]);
                        // a write is complete once the SDRAM has it
                        if (op_port_c) c_done_m <= !c_done_m; else a_done_m <= !a_done_m;
                    end
                end
                // READ issued when step was TRCD-1; dq_fall holds the pins at
                // the falling edge CL + 1.5 cycles later, usable one edge after
                if (!op_refresh && op_read && step == TRCD[4:0] - 5'd1 + CL[4:0] + 5'd2) begin
                    if (op_port_c) begin c_word_m <= dq_fall; c_done_m <= !c_done_m; end
                    else begin a_word_m <= dq_fall; a_done_m <= !a_done_m; end
                end
                if (step == OP_CYCLES[4:0] - 5'd2) state <= S_IDLE;   // next ACTIVE OP_CYCLES after this one
            end
            default: state <= S_INIT;
        endcase
    end
endmodule

`default_nettype wire
