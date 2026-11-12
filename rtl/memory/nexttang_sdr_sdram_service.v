// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Main memory for boards with SDR SDRAM (first user: the Tang Nano 20K's
// in-package 2M x 32 die). Serves the machine's memory ports A and C
// (rtl/platform/nexttang_next_machine.v, "memory contract") and refreshes.
//
// Port B (Layer 2). The core takes each Layer 2 byte four machine cycles
// after asking, too soon for an SDRAM read that may wait behind another
// access. So port B works from the core's announcements (b_pf_*: the same
// read eight pixels ahead): each goes into a 16-entry FIFO in order and is
// fetched ahead, with priority over ports A and C; a real request (b_*) takes
// the head entry, and its byte is registered at once. An announcement for the
// word the previous one fetched shares that read. If the head's address does
// not match the request (a Layer 2 setting changed within the lookahead), the
// FIFO is flushed and refills within eight pixels; a request with nothing
// ready counts as late. A CPU write to a Layer 2 word already fetched shows
// eight pixels later than on the official board.
//
// Clocking. memory_clock runs at three times machine_clock and both come from
// one PLL (the Nano: 84.375 and 28.125 MHz, the PLL's divide-by-3 output), so
// the clocks are related: requests cross by toggles and every crossing is a
// register-to-register path the static timer checks. Completion is taken
// into the machine domain by a register, so read data and the end of wait
// arrive together on a machine edge. The SDRAM gets the inverted memory
// clock (sdram_clk; a board may instead send it through an output DDR
// register in its I/O cell, as the Nano 20K does), so commands and write data
// sit mid-eye at its pins. Command, address and read capture are one register
// per pin, so a board can put them in the I/O cells; write data is driven a
// cycle early instead (below), so its routing has a cycle and a half.
//
// Accesses. One 32-bit word per ACTIVE, READ or WRITE with auto-precharge,
// CAS latency 2, burst length 1; a byte write uses the DQM lanes. Each
// access occupies the bank for OP_CYCLES (tRC), refresh likewise. Read data
// is taken from the pins on the falling memory-clock edge CL + 1.5 cycles
// after READ, the middle of the data window at these speeds (the bring-up
// self-test's capture B checks exactly this point on the board, at 81 MHz).
// The capture runs in its own pipeline, so the next access can start while
// a read's data is still on its way.
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
    parameter integer MEMORY_HZ    = 84_375_000,
    parameter integer TRCD         = 2,     // ACTIVE to READ/WRITE, cycles (23.7 ns); at least 2
    parameter integer OP_CYCLES    = 6,     // ACTIVE to next ACTIVE (tRC 60 ns; tWR + tRP after a write)
    parameter integer REFRESH_US10 = 78,    // refresh interval in 0.1 us (64 ms / 8192)
    parameter integer TIMEOUT      = 4096,  // port A memory cycles before fault_timeout
    // Read data capture: 1 (default) the pins at the falling edge CL + 1.5
    // cycles after READ, the middle of the data window at these speeds; 0 the
    // rising edge half a cycle earlier, at the window's leading edge. The
    // bring-up self-test measures both (its captures B and A) on the board.
    parameter integer CAPTURE      = 1
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

    // port B, Layer 2 (machine_clock): announcements and real reads
    input  wire        b_pf_toggle,
    input  wire [20:0] b_pf_address,
    input  wire        b_toggle,
    input  wire [20:0] b_address,
    output reg  [7:0]  b_data = 8'd0,
    output reg  [15:0] b_late = 16'd0,      // reads with nothing ready (saturating)
    output reg  [15:0] b_mismatch = 16'd0,  // reads whose announcement differed (saturating)

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
    reg        a_done_sync = 1'b0;      // completion, taken into the machine domain
    reg [31:0] a_word_sync = 32'd0;
    always @(posedge machine_clock) begin
        a_done_sync <= a_done_toggle;
        a_word_sync <= a_word;
    end
    wire       a_pending = a_toggle != a_done_sync;
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
    // a_word_sync is taken on the same machine edge as a_done_sync, so the
    // byte is valid from the cycle wait drops; a_lane is held.
    assign a_read_data = a_word_sync[8 * a_lane +: 8];
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
    reg        c_done_sync = 1'b0;
    reg [31:0] c_word_sync = 32'd0;
    always @(posedge machine_clock) begin
        c_done_sync <= c_done_toggle;
        c_word_sync <= c_word;
    end
    wire       c_pending = c_toggle != c_done_sync;
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
            c_read_data <= c_word_sync[8 * c_lane +: 8];
        end
    end

    // Port B, machine side: the announcement FIFO and the real reads.
    // Pointers are 5 bits over 16 slots; b_done (memory domain) counts the
    // slots whose word has arrived, in order.
    (* syn_ramstyle = "distributed_ram" *) reg [20:0] b_slot_address [0:15];
    reg [15:0] b_slot_dup = 16'd0;
    reg [4:0]  b_tail = 5'd0, b_head = 5'd0;
    reg        b_pf_prev = 1'b0, b_prev = 1'b0;
    reg [18:0] b_last_word = 19'd0;
    reg        b_have_last = 1'b0;
    reg        b_resync = 1'b0;
    wire [4:0] b_done;                       // memory domain
    wire [31:0] b_head_word;                 // memory domain slot data, read here
    wire       b_pf_event = b_pf_toggle != b_pf_prev;
    wire       b_event = b_toggle != b_prev;
    wire       b_empty = b_head == b_tail;
    wire       b_head_ready = (b_done - b_head) != 5'd0 && (b_done - b_head) <= (b_tail - b_head);
    always @(posedge machine_clock) begin
        b_pf_prev <= b_pf_toggle;
        b_prev <= b_toggle;
        if (b_pf_event) begin
            b_slot_address[b_tail[3:0]] <= b_pf_address;
            b_slot_dup[b_tail[3:0]] <= b_have_last && b_pf_address[20:2] == b_last_word;
            b_last_word <= b_pf_address[20:2];
            b_have_last <= 1'b1;
            b_tail <= b_tail + 5'd1;
        end
        if (b_event) begin
            if (b_empty) begin
                if (b_late != 16'hFFFF) b_late <= b_late + 16'd1;
            end else if (b_slot_address[b_head[3:0]] != b_address) begin
                // Out of step. Flush once: everything queued was announced
                // before the change, and the new announcements run eight
                // pixels ahead, so until a read reaches the first of them it
                // is late and leaves the queue alone (b_resync).
                if (!b_resync) begin
                    if (b_mismatch != 16'hFFFF) b_mismatch <= b_mismatch + 16'd1;
                    b_head <= b_tail;                // an entry pushed now stays
                    b_have_last <= 1'b0;
                    b_resync <= 1'b1;
                end else if (b_late != 16'hFFFF) b_late <= b_late + 16'd1;
            end else begin
                b_resync <= 1'b0;
                if (b_head_ready) b_data <= b_head_word[8 * b_address[1:0] +: 8];
                else if (b_late != 16'hFFFF) b_late <= b_late + 16'd1;
                b_head <= b_head + 5'd1;
            end
        end else if (b_pf_event && (b_tail - b_head) == 5'd16) begin
            b_head <= b_head + 5'd1;                 // full: drop the oldest
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

    // Write data and its output enable go out one memory cycle before the
    // WRITE command and stay through it (the bus is idle then: the previous
    // access's read data has finished). They reach the pins through fabric
    // routing (the four byte lanes carry one byte, one enable serves all 32
    // pins), whose delay moves with placement; launched with the WRITE, they
    // had only the half cycle (5.9 ns) before the SDRAM samples, and builds
    // that met timing corrupted memory and failed to boot while their
    // neighbours booted (2026-11-11). Now they have a cycle and a half.
    reg        dq_oe = 1'b0;
    reg [31:0] dq_out = 32'd0;
    assign sdram_dq = dq_oe ? dq_out : 32'bz;
    // at the capture edge (READ + CL + 2): CAPTURE 1 holds the pins at READ +
    // CL + 1.5 (falling edge), CAPTURE 0 the pins at READ + CL + 1 (rising).
    // Only the chosen register exists, so it can sit in the pin's I/O cell.
    reg [31:0] dq_capture = 32'd0;
    generate
        if (CAPTURE != 0) begin : capture_fall
            always @(negedge memory_clock) dq_capture <= sdram_dq;
        end else begin : capture_rise
            always @(posedge memory_clock) dq_capture <= sdram_dq;
        end
    endgenerate
    wire [31:0] dq_read = dq_capture;

    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

    localparam S_INIT = 3'd0, S_PRE = 3'd1, S_REF1 = 3'd2, S_REF2 = 3'd3, S_MRS = 3'd4,
               S_IDLE = 3'd5, S_OP = 3'd6;

    reg [2:0]  state = S_INIT;
    reg [15:0] init_count = 16'd0;     // power-up and initialisation waits only
    reg        init_wait = 1'b0;       // init_count still running
    reg [2:0]  step = 3'd0;            // cycles since ACTIVE (or REFRESH)
    reg [15:0] refresh_count = 16'd0;
    reg        refresh_tick = 1'b0;
    reg [1:0]  refresh_owed = 2'd0;
    reg        op_refresh = 1'b0, op_port_c = 1'b0, op_port_b = 1'b0, op_read = 1'b0;
    reg [20:0] op_address = 21'd0;
    reg [7:0]  op_data = 8'd0;
    reg [15:0] a_age = 16'd0;
    // read capture pipeline: bit k set k + 1 edges after READ; the port is
    // carried alongside
    reg [CL + 1:0] rd_pipe = 0;
    reg [CL + 1:0] rd_port_c = 0;
    reg [CL + 1:0] rd_port_b = 0;
    // port B, memory side
    (* syn_ramstyle = "distributed_ram" *) reg [31:0] b_slot_word [0:15];
    reg [4:0]  b_fetch = 5'd0;       // next slot to fetch
    reg [4:0]  b_done_m = 5'd0;      // slots whose word is in b_slot_word
    reg        b_busy = 1'b0;        // a port B read in flight
    reg [3:0]  b_fetch_slot = 4'd0;
    reg [31:0] b_last_word_m = 32'd0;
    assign b_done = b_done_m;
    assign b_head_word = b_slot_word[b_head[3:0]];
    // the machine side's pointers, registered here first (related clocks):
    // used straight from the machine domain, they fed this cycle's command
    // decision combinationally and the path missed 84 MHz by up to 1.9 ns
    // whenever placement moved (Nano 20K, 2026-11-11). A view one memory
    // cycle old is safe: a fetch already in flight during a flush is handled
    // the same way (b_fetch_stale waits for !b_busy).
    reg  [4:0] b_head_m = 5'd0, b_tail_m = 5'd0;
    always @(posedge memory_clock) begin
        b_head_m <= b_head;
        b_tail_m <= b_tail;
    end
    wire [4:0] b_window = b_tail_m - b_head_m;
    wire       b_fetch_stale = (b_fetch - b_head_m) > b_window;   // flushed past
    wire       b_want = !b_fetch_stale && b_fetch != b_tail_m && !b_busy;
    wire       b_want_read = b_want && !b_slot_dup[b_fetch[3:0]];

    wire a_new = a_toggle != a_seen_m;
    wire c_new = c_toggle != c_seen_m;
    wire refresh_now = refresh_owed[1] || (refresh_owed != 2'd0 && !a_new && !c_new);

    task automatic command(input [3:0] c);
        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= c;
    endtask

    reg refresh_take;
    always @(posedge memory_clock) begin
        refresh_take = 1'b0;
        command(C_NOP);
        dq_oe <= 1'b0;
        // refresh timer, its compare registered
        refresh_tick <= refresh_count == 16'd1;
        refresh_count <= (refresh_count == 16'd0) ? REFRESH_CYCLES[15:0] : refresh_count - 16'd1;
        if (a_new && a_age != 16'hFFFF) a_age <= a_age + 16'd1;
        if (a_age == TIMEOUT[15:0] * 16'd3) fault_timeout <= 1'b1;
        init_wait <= init_count > 16'd1;
        if (init_count != 16'd0) init_count <= init_count - 16'd1;

        // read data: the pins at the falling edge CL + 1.5 cycles after READ
        rd_pipe <= {rd_pipe[CL:0], 1'b0};
        rd_port_c <= {rd_port_c[CL:0], 1'b0};
        rd_port_b <= {rd_port_b[CL:0], 1'b0};
        if (rd_pipe[CL + 1]) begin
            if (rd_port_b[CL + 1]) begin
                b_slot_word[b_fetch_slot] <= dq_read; b_last_word_m <= dq_read;
                b_done_m <= b_done_m + 5'd1; b_busy <= 1'b0;
            end else if (rd_port_c[CL + 1]) begin c_word_m <= dq_read; c_done_m <= !c_done_m; end
            else begin a_word_m <= dq_read; a_done_m <= !a_done_m; end
        end
        // port B bookkeeping: skip slots a flush dropped; an announcement that
        // repeats the previous word takes the last word fetched
        if (b_fetch_stale && !b_busy) begin
            b_fetch <= b_head_m; b_done_m <= b_head_m;
        end else if (b_want && b_slot_dup[b_fetch[3:0]] && b_done_m == b_fetch) begin
            b_slot_word[b_fetch[3:0]] <= b_last_word_m;
            b_fetch <= b_fetch + 5'd1; b_done_m <= b_done_m + 5'd1;
        end

        if (reset) begin
            state <= S_INIT; init_count <= INIT_CYCLES[15:0]; init_wait <= 1'b1;
            sdram_cke <= 1'b0; ready <= 1'b0;
            sdram_dqm <= 4'hF; refresh_owed <= 2'd0; refresh_count <= REFRESH_CYCLES[15:0];
            a_seen_m <= a_toggle; a_done_m <= a_toggle; c_seen_m <= c_toggle; c_done_m <= c_toggle;
            fault_timeout <= 1'b0; a_age <= 16'd0; rd_pipe <= 0;
            b_busy <= 1'b0; b_fetch <= b_head_m; b_done_m <= b_head_m;
        end else case (state)
            S_INIT: begin
                sdram_cke <= 1'b1;
                if (!init_wait) state <= S_PRE;
            end
            S_PRE: begin
                command(C_PRE); sdram_addr <= 11'h400;
                init_count <= OP_CYCLES[15:0]; init_wait <= 1'b1; state <= S_REF1;
            end
            S_REF1: if (!init_wait) begin
                        command(C_REF); init_count <= 2 * OP_CYCLES; init_wait <= 1'b1; state <= S_REF2;
                    end
            S_REF2: if (!init_wait) begin
                        command(C_REF); init_count <= 2 * OP_CYCLES; init_wait <= 1'b1; state <= S_MRS;
                    end
            S_MRS: if (!init_wait) begin
                       command(C_MRS); sdram_ba <= 2'b00;
                       sdram_addr <= 11'b0000_010_0_000;    // burst write, CL 2, sequential, BL 1
                       step <= 3'd0; op_refresh <= 1'b1; state <= S_OP;   // tMRD, then idle
                   end
            S_IDLE: begin
                ready <= 1'b1;
                step <= 3'd0;
                if (refresh_owed[1] || (refresh_now && !b_want_read)) begin
                    command(C_REF); refresh_take = 1'b1;
                    op_refresh <= 1'b1; state <= S_OP;
                end else if (b_want_read && b_done_m == b_fetch) begin
                    // Layer 2 ahead of the CPU (one port B read in flight)
                    op_refresh <= 1'b0; op_port_c <= 1'b0; op_port_b <= 1'b1; op_read <= 1'b1;
                    op_address <= b_slot_address[b_fetch[3:0]];
                    b_fetch_slot <= b_fetch[3:0]; b_fetch <= b_fetch + 5'd1; b_busy <= 1'b1;
                    command(C_ACT); sdram_ba <= b_slot_address[b_fetch[3:0]][11:10];
                    sdram_addr <= {2'b00, b_slot_address[b_fetch[3:0]][20:12]};
                    state <= S_OP;
                end else if (a_new) begin
                    a_seen_m <= a_toggle; a_age <= 16'd0;
                    op_refresh <= 1'b0; op_port_c <= 1'b0; op_port_b <= 1'b0;
                    op_read <= !a_op_read_n; op_address <= a_op_address; op_data <= a_op_data;
                    command(C_ACT); sdram_ba <= a_op_address[11:10]; sdram_addr <= {2'b00, a_op_address[20:12]};
                    state <= S_OP;
                end else if (c_new) begin
                    c_seen_m <= c_toggle;
                    op_refresh <= 1'b0; op_port_c <= 1'b1; op_port_b <= 1'b0;
                    op_read <= !c_op_read_n; op_address <= c_op_address; op_data <= c_op_data;
                    command(C_ACT); sdram_ba <= c_op_address[11:10]; sdram_addr <= {2'b00, c_op_address[20:12]};
                    state <= S_OP;
                end
            end
            S_OP: begin
                step <= step + 3'd1;
                // write data on the bus from the cycle before WRITE
                if (!op_refresh && !op_read && step == TRCD[2:0] - 3'd2) begin
                    dq_oe <= 1'b1;
                    dq_out <= {4{op_data}};
                end
                if (!op_refresh && step == TRCD[2:0] - 3'd1) begin
                    sdram_ba <= op_address[11:10];
                    sdram_addr <= {3'b100, op_address[9:2]};      // A10: auto-precharge
                    if (op_read) begin
                        command(C_READ); sdram_dqm <= 4'h0;
                        rd_pipe[0] <= 1'b1; rd_port_c[0] <= op_port_c; rd_port_b[0] <= op_port_b;
                    end else begin
                        command(C_WRITE); dq_oe <= 1'b1;    // dq_out set the cycle before
                        sdram_dqm <= ~(4'b0001 << op_address[1:0]);
                        // a write is complete once the SDRAM has it
                        if (op_port_c) c_done_m <= !c_done_m; else a_done_m <= !a_done_m;
                    end
                end
                if (step == OP_CYCLES[2:0] - 3'd2) state <= S_IDLE;   // next ACTIVE OP_CYCLES after this one
            end
            default: state <= S_INIT;
        endcase
        // owed refreshes: +1 per tick, -1 per refresh issued, in one place
        if (!reset)
            refresh_owed <= refresh_owed + ((refresh_tick && refresh_owed != 2'd3) ? 2'd1 : 2'd0)
                                         - (refresh_take ? 2'd1 : 2'd0);
    end
endmodule

`default_nettype wire
