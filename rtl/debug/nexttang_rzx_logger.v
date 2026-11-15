// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Input recorder for RZX replay (docs/replay-and-rewind.md, step 1).
//
// An RZX input recording holds, for every frame, the number of instruction
// fetches the CPU made before the interrupt that ended the frame and the byte
// every IN instruction read during it (RZX format v0.13). Replaying those
// bytes from the same starting snapshot reproduces the run exactly.
//
// This module watches the Z80's own bus signals (not the DMA's) on the core
// clock and produces that information as a stream of 9-bit words:
//
//     {1'b0, byte}     the data byte of one I/O read, in program order
//     {1'b1, lo}       end of frame: the fetch count's low byte, then
//     {1'b1, hi}       its high byte
//
// so a frame is its IN bytes followed by two tagged words, and its IN count
// is the number of untagged words since the previous frame end.
//
// Fetches: one per M1 cycle that is not an interrupt acknowledge, which is
// the RZX counter (it follows the R register, 1 per opcode fetch and 2 for a
// prefixed instruction; HALT's internal NOP fetches count too). An M1 cycle
// during which IORQ goes low is an interrupt acknowledge: it ends the frame
// and is not counted. Whether an M1 cycle is an acknowledge is only known by
// its end, so both are decided on M1's rising edge.
//
// An interrupt the CPU does not take still ends a frame, as an emulator
// recording an RZX ends one at every frame interrupt and, on playback, only
// tries to interrupt there (Fuse: spectrum_frame_event_fn): when INT (int_n)
// goes low and rises again with no acknowledge in between, the frame ends at
// that rise. Without it, a stretch with interrupts disabled would merge frames
// past RZX's 16-bit count. Tie int_n high to end frames at acknowledges only.
//
// I/O reads: IORQ and RD low with M1 high. `data` is the CPU's own input
// register (the core's o_SPEC256_DI, the T80's DI_Reg), which latches the bus
// in T3 of every bus cycle and holds it until the next cycle's T3. It is
// taken one clock after IORQ rises, when it holds exactly what the IN read;
// the next latch is at least two T-states later (the following M1's T3).
//
// The count saturates at 65535 (a 3.5 MHz frame has fewer than 18,000
// fetches; faster CPU speeds belong to the later Next profile) and sets
// `saturated` until the next `start`. Words go through a small FIFO; if the
// consumer falls behind and the FIFO is full, the word is lost and `overflow`
// is set until the next `start`. Either flag makes the recording unusable.
//
// `start` clears the counters and flags and begins recording at the next
// clock; `stop` ends it. The frame in progress at `stop` gets no frame end
// (RZX frames end at interrupts), so a reader drops any untagged words after
// the last frame end.

`default_nettype none

module nexttang_rzx_logger #(
    parameter FIFO_BITS = 5
) (
    input  wire       clock,
    input  wire       reset,

    input  wire       start,
    input  wire       stop,
    output reg        recording,

    input  wire       m1_n,
    input  wire       iorq_n,
    input  wire       rd_n,
    input  wire [7:0] data,
    input  wire       int_n,

    output wire [8:0] word,
    output wire       word_valid,
    input  wire       word_ready,

    output reg [15:0] frames,
    output reg        saturated,
    output reg        overflow
);
    reg m1_n_q = 1'b1;
    reg io_rd_q = 1'b0;
    reg ack_seen = 1'b0;
    reg int_n_q = 1'b1;
    reg int_acked = 1'b0;        // an acknowledge since INT last went low
    reg [15:0] fetches = 16'd0;
    reg [7:0] count_hi = 8'h00;
    reg hi_pending = 1'b0;

    wire io_rd = !iorq_n && !rd_n && m1_n;
    wire m1_end = !m1_n_q && m1_n;
    wire io_end = io_rd_q && !io_rd;
    wire int_end = !int_n_q && int_n;
    // An interrupt that went unanswered: a frame end without an acknowledge.
    // (An acknowledge on this very clock is the ordinary frame end instead.)
    wire missed = int_end && !int_acked && !(m1_end && ack_seen);
    // An IN read ending now or its byte due now goes first (the read ended
    // before the interrupt did), and the missed frame end waits in
    // missed_pending, so its high byte (hi_pending, next clock) cannot meet
    // that byte.
    reg missed_pending = 1'b0;
    wire missed_now = (missed || missed_pending) && !io_end && !io_end_q;
    wire frame_end = (m1_end && ack_seen) || missed_now;
    reg io_end_q = 1'b0;

    // FIFO
    localparam DEPTH = 1 << FIFO_BITS;
    reg [8:0] fifo [0:DEPTH-1];
    reg [FIFO_BITS:0] wr_ptr = 0;
    reg [FIFO_BITS:0] rd_ptr = 0;
    wire empty = wr_ptr == rd_ptr;
    wire full = (wr_ptr[FIFO_BITS] != rd_ptr[FIFO_BITS]) &&
                (wr_ptr[FIFO_BITS-1:0] == rd_ptr[FIFO_BITS-1:0]);
    assign word = fifo[rd_ptr[FIFO_BITS-1:0]];
    assign word_valid = !empty;
    wire pop = word_valid && word_ready;

    // At most one word is pushed per clock: a frame end's high byte waits one
    // clock in hi_pending, and an IN byte is pushed one clock after its cycle.
    // The M1 cycle after an IN ends at least two T-states (two clocks at
    // 28 MHz) after it, so an acknowledge's frame end never meets an IN byte;
    // a missed interrupt's frame end is held off by missed_pending.
    reg push;
    reg [8:0] push_word;
    always @* begin
        push = 1'b0;
        push_word = 9'h000;
        if (recording) begin
            if (hi_pending) begin
                push = 1'b1;
                push_word = {1'b1, count_hi};
            end else if (io_end_q) begin
                push = 1'b1;
                push_word = {1'b0, data};
            end else if (frame_end) begin
                push = 1'b1;
                push_word = {1'b1, fetches[7:0]};
            end
        end
    end

    always @(posedge clock) begin
        m1_n_q <= m1_n;
        io_rd_q <= io_rd;
        io_end_q <= io_end;
        int_n_q <= int_n;
        missed_pending <= (missed || missed_pending) && (io_end || io_end_q) && recording;
        if (int_n_q && !int_n)
            int_acked <= 1'b0;
        else if (m1_end && ack_seen)
            int_acked <= 1'b1;
        if (!m1_n && !iorq_n)
            ack_seen <= 1'b1;
        else if (m1_end)
            ack_seen <= 1'b0;

        if (pop)
            rd_ptr <= rd_ptr + 1'b1;
        if (push) begin
            if (full && !pop)
                overflow <= 1'b1;
            else begin
                fifo[wr_ptr[FIFO_BITS-1:0]] <= push_word;
                wr_ptr <= wr_ptr + 1'b1;
            end
        end

        hi_pending <= 1'b0;
        if (recording && frame_end) begin
            count_hi <= fetches[15:8];
            hi_pending <= 1'b1;
            fetches <= (m1_end && !ack_seen) ? 16'd1 : 16'd0;   // a fetch ending on the same clock is the next frame's
            frames <= frames + 1'b1;
        end else if (recording && m1_end && !ack_seen) begin
            if (fetches == 16'hffff)
                saturated <= 1'b1;
            else
                fetches <= fetches + 1'b1;
        end

        if (stop)
            recording <= 1'b0;
        if (start) begin
            recording <= 1'b1;
            fetches <= 16'd0;
            frames <= 16'd0;
            saturated <= 1'b0;
            overflow <= 1'b0;
            hi_pending <= 1'b0;
            wr_ptr <= 0;
            rd_ptr <= 0;
        end
        if (reset) begin
            recording <= 1'b0;
            fetches <= 16'd0;
            frames <= 16'd0;
            saturated <= 1'b0;
            overflow <= 1'b0;
            hi_pending <= 1'b0;
            ack_seen <= 1'b0;
            m1_n_q <= 1'b1;
            io_rd_q <= 1'b0;
            io_end_q <= 1'b0;
            wr_ptr <= 0;
            rd_ptr <= 0;
        end
    end
endmodule

`default_nettype wire
