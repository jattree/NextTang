// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Which blocks of memory have been written since they were last saved, for
// the rewind ring's checkpoints (docs/replay-and-rewind.md, piece 4).
//
// One bit per block (256 bytes of the Next's 2 MB with the default
// BLOCK_BITS = 13: 8,192 bits, one block RAM). Every write sets its block's
// bit. A checkpoint asks for the dirty blocks with a scan:
//
//     scan_start      one clock; the scan runs from block 0 upwards
//     block_valid     `block` is dirty; held until block_ready
//     block_ready     the consumer takes the block: its bit is cleared, and
//                     the consumer copies the block afterwards
//     scan_done       one clock, after the last block has been looked at
//
// The bit is cleared when the block is taken, before it is copied, so a
// write that lands during or after the copy leaves the block dirty for the
// next checkpoint; nothing is lost if writes go on during a scan, only
// copied again. After reset every block is dirty: the first checkpoint is a
// full copy.
//
// The RAM has one write port: a write's set goes first, and a clear waits a
// clock for it. If the set and the waiting clear are for the same block the
// clear is dropped: the block was written after it was reported.

`default_nettype none

module nexttang_dirty_blocks #(
    parameter BLOCK_BITS = 13
) (
    input  wire                  clock,
    input  wire                  reset,

    input  wire                  write_valid_in,
    input  wire [BLOCK_BITS-1:0] write_block_in,

    input  wire                  scan_start,
    output wire                  block_valid,
    output wire [BLOCK_BITS-1:0] block,
    input  wire                  block_ready,
    output reg                   scan_done = 1'b0,
    output wire                  scanning
);
    localparam BLOCKS = 1 << BLOCK_BITS;
    reg bits [0:BLOCKS-1];

    // The write is registered on the way in: a board's write strobe comes
    // late in the cycle (the Next's is made from a half-cycle path), and a
    // clock's delay only makes the set later, which the clear already allows
    // for.
    reg                  write_valid = 1'b0;
    reg [BLOCK_BITS-1:0] write_block = 0;

    // At power-up and after a reset every bit is set, one a clock; a scan
    // waits for that. (No initial values for the RAM: Gowin's synthesis will
    // not run an 8,192-step initial loop.)
    reg                  filling = 1'b1;
    reg [BLOCK_BITS-1:0] fill_at = 0;

    localparam S_IDLE = 3'd0, S_READ = 3'd1, S_LOOK = 3'd2, S_OFFER = 3'd3, S_CLEAR = 3'd4;
    reg [2:0]            state = S_IDLE;
    reg [BLOCK_BITS-1:0] at = 0;
    reg                  read_bit = 1'b0;
    reg                  start_pending = 1'b0;

    assign scanning = state != S_IDLE || start_pending;
    assign block_valid = state == S_OFFER;
    assign block = at;

    wire clear_now = state == S_CLEAR && !write_valid && !filling;
    wire last = &at;

    always @(posedge clock) begin
        scan_done <= 1'b0;
        write_valid <= write_valid_in;
        write_block <= write_block_in;

        // The one write port: a fill, a set, or a clear.
        if (filling)
            bits[fill_at] <= 1'b1;
        else if (write_valid)
            bits[write_block] <= 1'b1;
        else if (clear_now)
            bits[at] <= 1'b0;
        read_bit <= bits[at];

        if (filling) begin
            fill_at <= fill_at + 1'b1;
            if (&fill_at)
                filling <= 1'b0;
        end

        if (scan_start)
            start_pending <= 1'b1;

        case (state)
            S_IDLE:
                if (start_pending && !filling) begin
                    start_pending <= 1'b0;
                    at <= 0;
                    state <= S_READ;
                end
            S_READ:                     // the address is in; the bit arrives next clock
                state <= S_LOOK;
            S_LOOK:
                // A write to this block in the two clocks since the read is
                // not in read_bit, but it has set the bit: the next scan
                // reports it.
                if (read_bit)
                    state <= S_OFFER;
                else if (last) begin
                    scan_done <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    at <= at + 1'b1;
                    state <= S_READ;
                end
            S_OFFER:
                if (block_ready)
                    state <= S_CLEAR;
            S_CLEAR:
                // Wait for the write port; a set of this very block meanwhile
                // replaces the clear.
                if (clear_now || (write_valid && !filling && write_block == at)) begin
                    if (last) begin
                        scan_done <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        at <= at + 1'b1;
                        state <= S_READ;
                    end
                end
            default: state <= S_IDLE;
        endcase

        if (reset) begin
            filling <= 1'b1;
            fill_at <= 0;
            state <= S_IDLE;
            start_pending <= 1'b0;
            scan_done <= 1'b0;
            write_valid <= 1'b0;
        end
    end
endmodule

`default_nettype wire
