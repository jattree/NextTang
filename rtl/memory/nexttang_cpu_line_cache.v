// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// A direct-mapped cache of 16-byte lines in front of the CPU memory path.
//
// The ZXNext core reaches main memory one byte at a time through its port A,
// and a byte from DDR3 takes 16 to 26 cycles of the 28 MHz clock. The cache
// keeps 2^INDEX_BITS lines (16 KiB by default) in block RAM and answers a hit
// with two cycles of wait: the first reads the line and its tag, the second
// compares the tag and takes the byte. A read miss fetches the whole line,
// stores it and answers from it.
//
// Writes go through to memory. A write that hits also updates the cached
// line, so the cache never holds data older than memory. A write completes for
// the CPU as soon as it has been handed on; the CPU is held only if its next
// access must also go to memory while that write is still on its way. Every
// main-memory write, from the CPU or the DMA, passes this one port, which is
// what keeps the cache coherent.
//
// The core raises its request for the whole of a memory cycle; wait follows
// the request until the cache has answered, then stays released until the
// request ends.
module nexttang_cpu_line_cache #(
    parameter integer INDEX_BITS = 10
) (
    input  wire         clock,
    input  wire         memory_available,

    input  wire         core_request,
    input  wire         core_read_n,
    input  wire [20:0]  core_address,
    input  wire [7:0]   core_write_data,
    output reg  [7:0]   core_read_data,
    output wire         core_wait,

    // To the memory path: one byte transaction at a time, request held until
    // complete. A read returns its whole line.
    output reg          down_request,
    output reg          down_read_n,
    output reg  [20:0]  down_address,
    output reg  [7:0]   down_write_data,
    input  wire         down_complete,
    input  wire [127:0] down_read_line
);
    localparam integer TAG_BITS = 21 - 4 - INDEX_BITS;
    localparam integer LINES = 1 << INDEX_BITS;

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_LOOKUP = 2'd1;
    localparam [1:0] STATE_STALL = 2'd2;
    localparam [1:0] STATE_MISS = 2'd3;

    reg [1:0] state = STATE_IDLE;
    reg       done = 1'b0;
    reg       request_seen = 1'b0;
    reg       down_busy = 1'b0;

    wire [INDEX_BITS-1:0] index = core_address[INDEX_BITS+3:4];
    wire [TAG_BITS-1:0]   tag = core_address[20:INDEX_BITS+4];
    wire [3:0]            lane = core_address[3:0];

    // ------------------------------------------------------------ storage
    reg [127:0]        data_ram [0:LINES-1];
    reg [TAG_BITS:0]   tag_ram [0:LINES-1];     // {valid, tag}
    reg [127:0]        line_q;
    reg [TAG_BITS:0]   tag_q;

    // Writes to the RAMs land one edge after they are decided, by which time
    // the CPU may have moved on, so the line they belong to is kept.
    reg                data_write;
    reg [127:0]        data_write_line;
    reg                tag_write;
    reg [INDEX_BITS-1:0] write_index;
    reg [TAG_BITS-1:0]   write_tag;

    integer clear;
    initial
        for (clear = 0; clear < LINES; clear = clear + 1)
            tag_ram[clear] = 0;

    always @(posedge clock) begin
        line_q <= data_ram[index];
        tag_q <= tag_ram[index];
        if (data_write)
            data_ram[write_index] <= data_write_line;
        if (tag_write)
            tag_ram[write_index] <= {1'b1, write_tag};
    end

    wire hit = tag_q[TAG_BITS] && tag_q[TAG_BITS-1:0] == tag;

    // The cached line with this write's byte laid over it.
    reg [127:0] merged_line;
    always @(*) begin
        merged_line = line_q;
        merged_line[lane * 8 +: 8] = core_write_data;
    end

    assign core_wait = !memory_available || (core_request && !done);

    // ------------------------------------------------------- the transaction
    task automatic issue_down;
        begin
            down_request <= 1'b1;
            down_read_n <= core_read_n;
            down_address <= core_address;
            down_write_data <= core_write_data;
            down_busy <= 1'b1;
        end
    endtask

    always @(posedge clock) begin
        data_write <= 1'b0;
        data_write_line <= merged_line;
        tag_write <= 1'b0;
        write_index <= index;
        write_tag <= tag;

        request_seen <= core_request;
        if (!core_request)
            done <= 1'b0;

        if (down_complete) begin
            down_request <= 1'b0;
            down_busy <= 1'b0;
        end

        case (state)
            STATE_IDLE: begin
                // The line and tag for this address are read on this edge.
                if (memory_available && core_request && !request_seen && !done)
                    state <= STATE_LOOKUP;
            end

            STATE_LOOKUP: begin
                if (core_read_n) begin
                    // A write updates a line it hits, on the same edge as
                    // this lookup's result is used.
                    if (hit)
                        data_write <= 1'b1;
                    if (down_busy) begin
                        state <= STATE_STALL;
                    end else begin
                        issue_down;
                        done <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end else if (hit) begin
                    core_read_data <= line_q[lane * 8 +: 8];
                    done <= 1'b1;
                    state <= STATE_IDLE;
                end else if (down_busy) begin
                    state <= STATE_STALL;
                end else begin
                    issue_down;
                    state <= STATE_MISS;
                end
            end

            STATE_STALL: begin
                // An earlier write is still on its way; this access goes to
                // memory once it is through, the cycle after its request drops.
                if (!down_busy && !down_request) begin
                    issue_down;
                    if (core_read_n) begin
                        done <= 1'b1;
                        state <= STATE_IDLE;
                    end else begin
                        state <= STATE_MISS;
                    end
                end
            end

            STATE_MISS: begin
                if (down_complete) begin
                    data_write <= 1'b1;
                    data_write_line <= down_read_line;
                    tag_write <= 1'b1;
                    core_read_data <= down_read_line[lane * 8 +: 8];
                    done <= 1'b1;
                    state <= STATE_IDLE;
                end
            end
        endcase
    end

    initial begin
        down_request = 1'b0;
        down_read_n = 1'b0;
        down_address = 0;
        down_write_data = 0;
        core_read_data = 0;
        data_write = 1'b0;
        tag_write = 1'b0;
        write_index = 0;
        write_tag = 0;
    end
endmodule

`default_nettype wire
