// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// The rewind ring's memory checkpoints (docs/replay-and-rewind.md, piece 4).
//
// Three regions of one byte-wide memory port:
//
//     LIVE    the machine's memory, 1 << (BLOCK_BITS + 8) bytes
//     COPY    the same size: LIVE as it was at the last checkpoint
//     RING    1 << RING_BITS bytes of undo records
//
// and the dirty-block tracker (nexttang_dirty_blocks) on the machine's
// writes to LIVE. All three commands need the machine stopped, and none of
// this module's own writes may reach the tracker.
//
//     prime        COPY := LIVE for every dirty block; the ring is emptied.
//                  The first command after reset, and after anything else
//                  than the machine has written LIVE.
//     checkpoint   for every dirty block, an undo record goes into the ring
//                  (the block's number, then its 256 bytes in COPY: what the
//                  block held at the checkpoint before) and COPY := LIVE.
//                  When the ring is full the oldest checkpoints are dropped.
//     rewind       back_steps = 0: LIVE := COPY for every dirty block, which
//                  is the last checkpoint. back_steps = n: then the undo
//                  records of the n newest checkpoints, newest first, into
//                  LIVE and COPY, which is the checkpoint n before the last.
//                  Those n checkpoints leave the ring. n is cut to the
//                  number held (went_back says how many were undone).
//
// So after a rewind LIVE = COPY = the chosen checkpoint and nothing is dirty.
// `held` is how many checkpoints can be undone. A checkpoint with more dirty
// blocks than the whole ring holds cannot be kept: `overrun` is set, the ring
// is emptied and the checkpoint counts as a prime.
//
// The memory port: mem_request is held with the address (and data, for a
// write) until mem_ack, a one-clock pulse; read data is taken with the ack.

`default_nettype none

module nexttang_rewind_store #(
    parameter BLOCK_BITS = 13,                 // 256-byte blocks in LIVE
    parameter RING_BITS  = 22,                 // bytes of undo ring (a power of two)
    parameter TABLE_BITS = 8,                  // checkpoints remembered
    parameter ADDRESS_BITS = 23,
    // Each region starts on a multiple of its own size, so an address is
    // the base with the offset in its low bits (no adders).
    parameter [ADDRESS_BITS-1:0] LIVE_BASE = 0,
    parameter [ADDRESS_BITS-1:0] COPY_BASE = 23'h200000,
    parameter [ADDRESS_BITS-1:0] RING_BASE = 23'h400000
) (
    input  wire                    clock,
    input  wire                    reset,

    input  wire                    prime,
    input  wire                    checkpoint,
    input  wire                    rewind,
    input  wire [TABLE_BITS:0]     back_steps,
    output wire                    busy,
    output reg                     done = 1'b0,        // one clock
    output reg  [TABLE_BITS:0]     held = 0,
    output reg  [TABLE_BITS:0]     went_back = 0,
    output reg                     overrun = 1'b0,     // until the next command

    // the dirty-block tracker
    output reg                     scan_start = 1'b0,
    input  wire                    block_valid,
    input  wire [BLOCK_BITS-1:0]   block,
    output reg                     block_ready = 1'b0,
    input  wire                    scan_done,

    // memory
    output reg                     mem_request = 1'b0,
    output reg                     mem_write = 1'b0,
    output reg  [ADDRESS_BITS-1:0] mem_address = 0,
    output reg  [7:0]              mem_write_data = 8'h00,
    input  wire [7:0]              mem_read_data,
    input  wire                    mem_ack
);
    localparam RECORD = 258;                           // 256 bytes and the block number
    localparam [RING_BITS:0] RING_BYTES = 1 << RING_BITS;
    localparam [BLOCK_BITS+2:0] RING_RECORDS = RING_BYTES / RECORD;    // whole records the ring holds
    localparam TABLE = 1 << TABLE_BITS;

    // What is being done, and where in it.
    localparam M_PRIME = 2'd0, M_CHECKPOINT = 2'd1, M_REWIND = 2'd2;
    reg [1:0] mode = M_PRIME;

    localparam S_IDLE = 4'd0, S_SCAN = 4'd1, S_ROOM = 4'd2, S_BYTE = 4'd3, S_NUMBER = 4'd4,
               S_NEXT = 4'd5, S_CLOSE = 4'd6, S_POP = 4'd7, S_RECORD = 4'd8, S_UNDO = 4'd9,
               S_FINISH = 4'd10;
    reg [3:0] state = S_IDLE;
    assign busy = state != S_IDLE;

    // The ring and the table of checkpoints in it.
    reg [RING_BITS-1:0]  head = 0;                     // where the next record goes
    reg [BLOCK_BITS+2:0] used = 0;                     // records held
    reg [RING_BITS-1:0]  table_start [0:TABLE-1];
    reg [BLOCK_BITS:0]   table_count [0:TABLE-1];
    reg [TABLE_BITS-1:0] table_next = 0;               // where the next checkpoint's entry goes
    reg [RING_BITS-1:0]  this_start = 0;               // the checkpoint being written or undone
    reg [BLOCK_BITS:0]   this_count = 0;
    reg                  keeping = 1'b0;               // this checkpoint's undo records are being kept
    reg [TABLE_BITS:0]   steps_left = 0;

    wire [TABLE_BITS-1:0] oldest = table_next - held[TABLE_BITS-1:0];
    wire [TABLE_BITS-1:0] newest = table_next - 1'b1;
    reg  [RING_BITS-1:0]  entry_start = 0;             // a table entry, read a clock ahead
    reg  [BLOCK_BITS:0]   entry_count = 0;
    reg  [TABLE_BITS-1:0] entry_at = 0;

    // The block and byte under way.
    reg [BLOCK_BITS-1:0] this_block = 0;
    reg [8:0]            index = 0;                    // byte within the block, 256 = done
    reg [2:0]            phase = 0;                    // accesses within a byte
    reg [7:0]            data = 8'h00;
    reg [BLOCK_BITS:0]   records_left = 0;
    reg                  scan_finished = 1'b0;         // scan_done is one clock; it may come mid-copy
    wire [15:0]          number_out = {{(16 - BLOCK_BITS){1'b0}}, this_block};
    reg [15:0]           number_in = 16'd0;

    wire [ADDRESS_BITS-1:0] live_address = LIVE_BASE | {this_block, index[7:0]};
    wire [ADDRESS_BITS-1:0] copy_address = COPY_BASE | {this_block, index[7:0]};
    function [ADDRESS_BITS-1:0] ring_address(input [RING_BITS-1:0] position);
        ring_address = RING_BASE | position;
    endfunction

    task read(input [ADDRESS_BITS-1:0] address); begin
        mem_request <= 1'b1; mem_write <= 1'b0; mem_address <= address;
    end endtask
    task write(input [ADDRESS_BITS-1:0] address, input [7:0] value); begin
        mem_request <= 1'b1; mem_write <= 1'b1; mem_address <= address; mem_write_data <= value;
    end endtask

    always @(posedge clock) begin
        done <= 1'b0;
        scan_start <= 1'b0;
        block_ready <= 1'b0;
        if (mem_ack)
            mem_request <= 1'b0;
        entry_start <= table_start[entry_at];
        entry_count <= table_count[entry_at];
        if (scan_done)
            scan_finished <= 1'b1;

        case (state)
            S_IDLE: begin
                if (prime || checkpoint || rewind) begin
                    overrun <= 1'b0;
                    went_back <= 0;
                    scan_start <= 1'b1;
                    scan_finished <= 1'b0;
                    state <= S_SCAN;
                    this_start <= head;
                    this_count <= 0;
                end
                if (prime) begin
                    mode <= M_PRIME;
                    keeping <= 1'b0;
                    head <= 0;
                    used <= 0;
                    held <= 0;
                end else if (checkpoint) begin
                    mode <= M_CHECKPOINT;
                    keeping <= 1'b1;
                end else if (rewind) begin
                    mode <= M_REWIND;
                    steps_left <= back_steps > held ? held : back_steps;
                end
            end

            // The dirty blocks, one at a time.
            S_SCAN:
                if (block_valid && !block_ready) begin
                    this_block <= block;
                    block_ready <= 1'b1;          // taken now, copied next
                    index <= 0;
                    phase <= 0;
                    entry_at <= oldest;
                    state <= mode == M_CHECKPOINT && keeping ? S_ROOM : S_BYTE;
                end else if (scan_finished && !block_valid && !block_ready) begin
                    phase <= 0;
                    state <= mode == M_REWIND ? S_POP : S_CLOSE;
                end

            // Room for one more record: drop the oldest checkpoints until
            // there is. With none left to drop, this checkpoint alone is
            // more than the ring: give its undo records up.
            S_ROOM:
                if (phase == 0)
                    phase <= 1;                   // entry_at's entry arrives
                else if (used != RING_RECORDS) begin
                    phase <= 0;
                    state <= S_NUMBER;
                end else if (held != 0) begin
                    used <= used - entry_count;
                    held <= held - 1'b1;
                    entry_at <= entry_at + 1'b1;
                    phase <= 0;
                end else begin
                    overrun <= 1'b1;
                    keeping <= 1'b0;
                    head <= 0;
                    used <= 0;
                    this_start <= 0;
                    this_count <= 0;
                    phase <= 0;
                    state <= S_BYTE;
                end

            // One byte of the block. Checkpoint: COPY -> ring, LIVE -> COPY.
            // Prime: LIVE -> COPY. Rewind's first part: COPY -> LIVE.
            S_BYTE:
                if (index[8]) begin
                    phase <= 0;
                    if (mode == M_CHECKPOINT && keeping) begin
                        used <= used + 1'b1;
                        this_count <= this_count + 1'b1;
                    end
                    state <= S_NEXT;
                end else if (!mem_request) case (phase)
                    3'd0: begin
                        if (mode == M_CHECKPOINT && keeping) begin
                            read(copy_address);
                            phase <= 3'd1;
                        end else begin
                            read(mode == M_REWIND ? copy_address : live_address);
                            phase <= 3'd3;
                        end
                    end
                    3'd2: begin                   // the old copy's byte into the ring
                        write(ring_address(head), data);
                        head <= head + 1'b1;
                        phase <= 3'd5;
                    end
                    3'd4: begin
                        write(mode == M_REWIND ? live_address : copy_address, data);
                        phase <= 3'd7;
                    end
                    3'd6: begin                   // then the live byte
                        read(live_address);
                        phase <= 3'd3;
                    end
                    default: ;
                endcase else if (mem_ack) begin
                    data <= mem_read_data;
                    case (phase)
                        3'd1: phase <= 3'd2;
                        3'd3: phase <= 3'd4;
                        3'd5: phase <= 3'd6;
                        default: begin            // 7: the byte is done
                            phase <= 3'd0;
                            index <= index + 1'b1;
                        end
                    endcase
                end

            // A record begins with its block number, low byte then high.
            S_NUMBER:
                if (!mem_request) begin
                    if (phase == 3'd2) begin
                        phase <= 0;
                        state <= S_BYTE;
                    end else begin
                        write(ring_address(head), phase == 3'd0 ? number_out[7:0] : number_out[15:8]);
                        head <= head + 1'b1;
                        phase <= phase + 1'b1;
                    end
                end

            S_NEXT:
                state <= S_SCAN;

            // End of a prime or a checkpoint.
            S_CLOSE: begin
                if (mode == M_CHECKPOINT && keeping && held == TABLE) begin
                    // The table is full: its oldest checkpoint goes first,
                    // and its records' room with it.
                    entry_at <= oldest;
                    phase <= 0;
                    state <= S_FINISH;
                end else begin
                    if (mode == M_CHECKPOINT && keeping) begin
                        table_start[table_next] <= this_start;
                        table_count[table_next] <= this_count;
                        table_next <= table_next + 1'b1;
                        held <= held + 1'b1;
                    end
                    done <= 1'b1;
                    state <= S_IDLE;
                end
            end
            S_FINISH:
                if (phase != 3'd2)
                    phase <= phase + 1'b1;
                else begin
                    used <= used - entry_count;
                    held <= held - 1'b1;
                    phase <= 0;
                    state <= S_CLOSE;
                end

            // Rewind's second part: undo the newest checkpoint, steps_left times.
            S_POP:
                if (steps_left == 0) begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end else if (phase == 0) begin
                    entry_at <= newest;
                    phase <= 1;
                end else if (phase == 1)
                    phase <= 2;
                else begin
                    this_start <= entry_start;        // head walks the records, then comes back here
                    records_left <= entry_count;
                    head <= entry_start;
                    used <= used - entry_count;
                    table_next <= newest;
                    held <= held - 1'b1;
                    steps_left <= steps_left - 1'b1;
                    went_back <= went_back + 1'b1;
                    phase <= 0;
                    state <= S_RECORD;
                end

            // A record: its block number, then its 256 bytes, read in order.
            S_RECORD:
                if (records_left == 0) begin
                    head <= this_start;
                    phase <= 0;
                    state <= S_POP;
                end else if (!mem_request) begin
                    if (phase == 3'd0) begin
                        read(ring_address(head));
                        head <= head + 1'b1;
                        phase <= 3'd1;
                    end else if (phase == 3'd2) begin
                        read(ring_address(head));
                        head <= head + 1'b1;
                        phase <= 3'd3;
                    end else if (phase == 3'd4) begin
                        this_block <= number_in[BLOCK_BITS-1:0];
                        index <= 0;
                        phase <= 0;
                        state <= S_UNDO;
                    end
                end else if (mem_ack) begin
                    if (phase == 3'd1)
                        number_in[7:0] <= mem_read_data;
                    else
                        number_in[15:8] <= mem_read_data;
                    phase <= phase + 1'b1;
                end

            // Its bytes into LIVE and COPY.
            S_UNDO:
                if (index[8]) begin
                    records_left <= records_left - 1'b1;
                    phase <= 0;
                    state <= S_RECORD;
                end else if (!mem_request) case (phase)
                    3'd0: begin read(ring_address(head)); head <= head + 1'b1; phase <= 3'd1; end
                    3'd2: begin write(live_address, data); phase <= 3'd3; end
                    3'd4: begin write(copy_address, data); phase <= 3'd5; end
                    default: ;
                endcase else if (mem_ack) begin
                    if (phase == 3'd1)
                        data <= mem_read_data;
                    if (phase == 3'd5) begin
                        phase <= 3'd0;
                        index <= index + 1'b1;
                    end else
                        phase <= phase + 1'b1;
                end

            default: state <= S_IDLE;
        endcase

        if (reset) begin
            state <= S_IDLE;
            mem_request <= 1'b0;
            head <= 0;
            used <= 0;
            held <= 0;
            table_next <= 0;
            overrun <= 1'b0;
            done <= 1'b0;
            phase <= 0;
        end
    end
endmodule

`default_nettype wire
