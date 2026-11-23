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
// are zero: the Next's 2 MiB is a quarter of the die). Port C alone takes two
// more address bits, [22:21], as those two row bits: the whole 8 MiB, for a
// board that keeps something beside the Next's memory there (the rewind
// ring). A board with only the core on port C ties them to zero.

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
    parameter integer CAPTURE      = 1,
    // Keep the last WORD_CACHE words read for port A (2 or 4) and answer
    // reads of them without waiting for the SDRAM (see word_cache). 0 leaves
    // the cache out.
    parameter integer WORD_CACHE   = 0
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
    input  wire [22:0] c_address,
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
    // Completion crosses in one machine stage. The clocks are related and the
    // static timer checks the crossing (the machine clock rises half a memory
    // cycle after the memory clock), word and toggle alike. Until 2026-11-21
    // there were two stages, which cost every read a machine cycle of wait
    // for nothing.
    reg        a_done_sync = 1'b0;
    reg [31:0] a_word_sync = 32'd0;
    always @(posedge machine_clock) begin
        a_done_sync <= a_done_toggle;
        a_word_sync <= a_word;
    end
    wire       a_pending = a_toggle != a_done_sync;
    // A read holds the CPU from the request's own cycle, before the core can
    // sample wait, until its data is here. A write does not hold it: the
    // official board's SRAM takes a write with no wait at any speed, so the
    // address and byte are taken at the request and the CPU goes on while the
    // SDRAM does the write. Only a request that arrives while the previous
    // access (always such a write) is still outstanding waits, held as
    // a_deferred with the CPU stopped, and starts when that one is done.
    // Only the flag is kept, not the address and byte: a held write is taken
    // on the edge after wait drops, and both masters (the T80 and the zxnDMA)
    // keep their address and data up through that edge.
    reg        a_deferred = 1'b0;       // a request waits for the outstanding access
    reg        a_holds = 1'b0;          // the outstanding access is a read
    wire       a_unstarted = a_request || a_deferred;
    // The word cache (WORD_CACHE; below). Every SDRAM read brings back four
    // bytes; the last four words read are kept, and a read of a byte in one
    // of them is answered from here. Wait is raised with the request as for
    // any read and dropped one machine cycle later with the byte. The CPU
    // samples wait at the end of T2: at 14 MHz and below that is later still,
    // so the read costs no wait, and at 28 MHz it falls together with the
    // core's own one wait state. Both are the official SRAM's timing.
    // The cache is kept out of the decision to start an SDRAM access, which
    // is the machine's longest path (half a cycle from the CPU's strobes to
    // some thirty registers): a cached read starts its SDRAM read like any
    // other and lets it finish unused (a_holds clear). Of the cache's own
    // logic only two flags (k_read_r, k_merge_r) are decided from the request
    // on its edge; everything else follows from them a cycle later.
    wire       a_read_hit;              // this request is a read the cache holds
    wire       k_hit_r;                 // ... and its byte arrives on this edge
    wire       c_write_busy;
    reg        a_use_hit = 1'b0;        // the last read was answered by the cache
    reg  [7:0] a_hit_byte = 8'd0;
    wire       a_start = a_unstarted && !a_pending;
    assign a_wait = a_cycle_request && ((a_unstarted && (a_pending || !a_read_n)) || (a_pending && a_holds) || k_hit_r);
    always @(posedge machine_clock) begin
        if (a_start) begin
            a_toggle <= !a_toggle;
            a_op_read_n <= a_read_n;
            a_op_address <= a_address;
            a_op_data <= a_write_data;
            a_holds <= !a_read_n;
            if (!a_read_n) begin a_lane <= a_address[1:0]; a_use_hit <= 1'b0; end
            a_deferred <= 1'b0;
        end else if (a_request) a_deferred <= 1'b1;
        // any read's lane (a new read only comes once the last one's byte is taken)
        if (a_unstarted && !a_read_n) a_lane <= a_address[1:0];
        // A cached read, the edge after its request (k_hit_r): its byte is
        // loaded on this edge, and an SDRAM read started for it, on the
        // request's edge or on this one, is not waited for.
        if (k_hit_r) begin
            a_use_hit <= 1'b1;
            a_deferred <= 1'b0;
            a_holds <= 1'b0;
        end
        if (!a_cycle_request) a_deferred <= 1'b0;
    end
    generate
    if (WORD_CACHE != 0) begin : word_cache
        // Two or four entries (WORD_CACHE; with two, entries 2 and 3 are never
        // filled and fall away): a 19-bit word address and a valid bit each
        // in registers, the words in distributed RAM. Replacement goes round.
        // - A read that misses fills an entry the cycle after its data
        //   arrives (a_word_sync still holds it).
        // - A CPU or DMA write to a cached word replaces its byte in the
        //   entry on the edge that takes the write, so a posted write is
        //   seen by the next read at once.
        // - A port C write (the debugger, a Pi, the rewind ring) empties the
        //   cache for as long as it is outstanding, and a read that was under
        //   way at any time during it does not fill: the SDRAM serves port A
        //   first, so that read may have gone out ahead of the write.
        reg [18:0] k_tag [0:3];
        reg [3:0]  k_valid = 4'd0;
        (* syn_ramstyle = "distributed_ram" *) reg [31:0] k_word [0:3];
        reg [1:0]  k_next = 2'd0;
        reg        k_poison = 1'b0;     // a port C write overlapped the read under way
        reg        a_pending_d = 1'b0;
        wire [3:0] k_match = {k_valid[3] && k_tag[3] == a_address[20:2], k_valid[2] && k_tag[2] == a_address[20:2],
                              k_valid[1] && k_tag[1] == a_address[20:2], k_valid[0] && k_tag[0] == a_address[20:2]};
        wire       k_hit = |k_match;
        assign a_read_hit = !a_read_n && k_hit && a_unstarted;
        // The entry is chosen on the request's edge and its word read or
        // rewritten on the next, so the address compare ends in registers.
        reg        k_read_r = 1'b0;     // a cached read's byte is due
        reg        k_merge_r = 1'b0;    // a write's byte goes into its entry
        reg [1:0]  k_sel = 2'd0;
        reg [1:0]  k_merge_lane = 2'd0;
        reg [7:0]  k_merge_byte = 8'd0;
        assign k_hit_r = k_read_r;
        wire [31:0] k_read = k_word[k_sel];
        wire       k_merge = a_start && a_read_n && k_hit;
        // A fill happens on the edge after its read's wait dropped (E + 1,
        // the wait having dropped after E), and a request taken on that same
        // edge would be compared with the entries as they were. Neither
        // master can make one: the T80 samples wait at E + 1 at the earliest,
        // and the zxnDMA, which drops its strobe on the falling edge after E,
        // raises the next on the falling edge after E + 1, so its request is
        // taken at E + 2, with the filled entry in place. (Giving way to a
        // request on the fill edge was built and cost some 250 LUTs: the
        // core's late request signal in the fill enable. 2026-11-21.)
        wire       k_fill = a_holds && a_pending_d && !a_pending && !k_poison && !c_write_busy && !k_merge_r;
        wire [31:0] k_merged = {k_merge_lane == 2'd3 ? k_merge_byte : k_read[31:24],
                                k_merge_lane == 2'd2 ? k_merge_byte : k_read[23:16],
                                k_merge_lane == 2'd1 ? k_merge_byte : k_read[15:8],
                                k_merge_lane == 2'd0 ? k_merge_byte : k_read[7:0]};
        integer k;
        initial for (k = 0; k < 4; k = k + 1) k_tag[k] = 19'd0;
        always @(posedge machine_clock) begin
            a_pending_d <= a_pending;
            k_read_r <= a_read_hit && !k_read_r;   // once: a_deferred may still be up for a cycle
            k_merge_r <= k_merge;
            // taken every cycle and used only on the edge after a hit or a merge
            k_sel <= {k_match[3] | k_match[2], k_match[3] | k_match[1]};
            k_merge_lane <= a_address[1:0];
            k_merge_byte <= a_write_data;
            if (k_read_r) a_hit_byte <= k_read[8 * a_lane +: 8];
            if (a_start && !a_read_n) k_poison <= 1'b0;
            if (k_merge_r || k_fill) k_word[k_merge_r ? k_sel : k_next] <= k_merge_r ? k_merged : a_word_sync;
            if (k_fill) begin
                k_tag[k_next] <= a_op_address[20:2];
                k_valid[k_next] <= 1'b1;
                k_next <= (WORD_CACHE > 2) ? k_next + 2'd1 : {1'b0, !k_next[0]};
            end
            if (c_write_busy) begin k_valid <= 4'd0; k_poison <= 1'b1; end
        end
    end else begin : no_word_cache
        assign a_read_hit = 1'b0;
        assign k_hit_r = 1'b0;
    end
    endgenerate
    // The byte is valid from the cycle wait drops; a_lane is the last read's.
    assign a_read_data = a_use_hit ? a_hit_byte : a_word_sync[8 * a_lane +: 8];
    // Port C: same handshake, acknowledged with a one-cycle pulse.
    reg        c_toggle = 1'b0;
    reg        c_op_read_n = 1'b0;
    reg [22:0] c_op_address = 23'd0;
    reg [7:0]  c_op_data = 8'd0;
    wire       c_done_toggle;
    wire [7:0]  c_word;                 // port C's byte, picked on the memory side
    reg        c_seen = 1'b0;
    reg        c_armed = 1'b1;          // the request has been low since the last ack
    reg        c_done_meta = 1'b0, c_done_sync = 1'b0;
    reg [7:0]  c_word_sync = 8'd0;
    always @(posedge machine_clock) begin
        c_done_meta <= c_done_toggle;
        c_done_sync <= c_done_meta;
        c_word_sync <= c_word;
    end
    wire       c_pending = c_toggle != c_done_sync;
    assign c_busy = c_request || c_pending;
    // a port C write from its request until the SDRAM has it (word cache)
    assign c_write_busy = (c_request && c_read_n) || ((c_seen || c_pending) && c_op_read_n);
    always @(posedge machine_clock) begin
        c_ack <= 1'b0;
        if (!c_request) c_armed <= 1'b1;
        // The requester sees the ack a cycle late and still holds its request
        // in that cycle: only a request that has been low since the last ack
        // is a new one.
        if (c_request && c_armed && !c_pending && !c_seen) begin
            c_toggle <= !c_toggle; c_seen <= 1'b1; c_armed <= 1'b0;
            c_op_read_n <= c_read_n; c_op_address <= c_address; c_op_data <= c_write_data;
        end else if (c_seen && !c_pending) begin
            c_ack <= 1'b1; c_seen <= 1'b0;
            c_read_data <= c_word_sync;
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
    // b_done is registered here first: read combinationally from the memory
    // domain it had 5.9 ns to reach b_data's enable (half a memory cycle).
    reg  [4:0] b_done_s = 5'd0;
    wire       b_head_ready = (b_done_s - b_head) != 5'd0 && (b_done_s - b_head) <= (b_tail - b_head);
    always @(posedge machine_clock) begin
        b_done_s <= b_done;
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
    reg [31:0] a_word_m = 32'd0;
    reg [7:0]  c_word_m = 8'd0;
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
    localparam integer REFRESH_W = $clog2(REFRESH_CYCLES + 1);   // as wide as its limit, not 16 bits
    localparam [REFRESH_W-1:0] REFRESH_FIRST = REFRESH_CYCLES;
    reg [REFRESH_W-1:0] refresh_count = {REFRESH_W{1'b0}};
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
    wire       b_arrived = rd_pipe[CL + 1] && rd_port_b[CL + 1];
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
    wire       b_repeat = b_want && b_slot_dup[b_fetch[3:0]] && b_done_m == b_fetch && !b_arrived;
    // The decision to fetch is taken from a registered copy. Straight from
    // the pointers it ran through two subtractions and a compare into the
    // command and address registers' enables, the longest path on the memory
    // clock and a regular timing failure (2026-11-21). A copy one cycle old is
    // safe for the same reason as the pointers above: at worst a fetch goes
    // out for a slot that was flushed in that cycle, which is the fetch in
    // flight during a flush again. A fetch always leaves S_IDLE for several
    // cycles, so the copy is fresh whenever it is next used.
    reg        b_want_read_r = 1'b0;
    always @(posedge memory_clock) b_want_read_r <= b_want_read;

    // The request toggles are registered in the memory domain before the
    // command decision: read combinationally they had 5.9 ns to get through
    // it (the machine clock rises half a memory cycle after the memory
    // clock) and missed by up to 1.8 ns. The request's address and data were
    // set with the toggle, so they are a memory cycle old when used.
    reg a_toggle_m = 1'b0, c_toggle_m = 1'b0;
    always @(posedge memory_clock) begin
        a_toggle_m <= a_toggle;
        c_toggle_m <= c_toggle;
    end
    wire a_new = a_toggle_m != a_seen_m;
    wire c_new = c_toggle_m != c_seen_m;
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
        refresh_tick <= refresh_count == {{(REFRESH_W-1){1'b0}}, 1'b1};
        refresh_count <= (refresh_count == {REFRESH_W{1'b0}}) ? REFRESH_FIRST : refresh_count - 1'b1;
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
                b_last_word_m <= dq_read;
                b_done_m <= b_done_m + 5'd1; b_busy <= 1'b0;
            end else if (rd_port_c[CL + 1]) begin
                // only the requested byte crosses back (c_op_address holds until the ack)
                c_word_m <= dq_read[8 * c_op_address[1:0] +: 8]; c_done_m <= !c_done_m;
            end
            else begin a_word_m <= dq_read; a_done_m <= !a_done_m; end
        end
        // port B bookkeeping: skip slots a flush dropped; an announcement that
        // repeats the previous word takes the last word fetched
        if (b_fetch_stale && !b_busy) begin
            b_fetch <= b_head_m; b_done_m <= b_head_m;
        end else if (b_repeat) begin
            b_fetch <= b_fetch + 5'd1; b_done_m <= b_done_m + 5'd1;
        end
        // The one write into the slot words: a fetched word, or the last
        // word again for an announcement that repeats it. Written from two
        // places, the array was built as 512 registers and a mux tree, not
        // as distributed RAM (2026-11-17); the two never fall on one clock
        // (a repeat needs every started fetch to be done), and if they did
        // the repeat would wait a clock.
        if (b_arrived || b_repeat)
            b_slot_word[b_arrived ? b_fetch_slot : b_fetch[3:0]] <= b_arrived ? dq_read : b_last_word_m;

        if (reset) begin
            state <= S_INIT; init_count <= INIT_CYCLES[15:0]; init_wait <= 1'b1;
            sdram_cke <= 1'b0; ready <= 1'b0;
            sdram_dqm <= 4'hF; refresh_owed <= 2'd0; refresh_count <= REFRESH_FIRST;
            a_seen_m <= a_toggle_m; a_done_m <= a_toggle_m; c_seen_m <= c_toggle_m; c_done_m <= c_toggle_m;
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
                if (refresh_owed[1] || (refresh_now && !b_want_read_r)) begin
                    command(C_REF); refresh_take = 1'b1;
                    op_refresh <= 1'b1; state <= S_OP;
                end else if (b_want_read_r && b_done_m == b_fetch) begin
                    // Layer 2 ahead of the CPU (one port B read in flight)
                    op_refresh <= 1'b0; op_port_c <= 1'b0; op_port_b <= 1'b1; op_read <= 1'b1;
                    op_address <= b_slot_address[b_fetch[3:0]];
                    b_fetch_slot <= b_fetch[3:0]; b_fetch <= b_fetch + 5'd1; b_busy <= 1'b1;
                    command(C_ACT); sdram_ba <= b_slot_address[b_fetch[3:0]][11:10];
                    sdram_addr <= {2'b00, b_slot_address[b_fetch[3:0]][20:12]};
                    state <= S_OP;
                end else if (a_new) begin
                    a_seen_m <= a_toggle_m; a_age <= 16'd0;
                    op_refresh <= 1'b0; op_port_c <= 1'b0; op_port_b <= 1'b0;
                    op_read <= !a_op_read_n; op_address <= a_op_address; op_data <= a_op_data;
                    command(C_ACT); sdram_ba <= a_op_address[11:10]; sdram_addr <= {2'b00, a_op_address[20:12]};
                    state <= S_OP;
                end else if (c_new) begin
                    c_seen_m <= c_toggle_m;
                    op_refresh <= 1'b0; op_port_c <= 1'b1; op_port_b <= 1'b0;
                    op_read <= !c_op_read_n; op_address <= c_op_address[20:0]; op_data <= c_op_data;
                    command(C_ACT); sdram_ba <= c_op_address[11:10]; sdram_addr <= c_op_address[22:12];
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
