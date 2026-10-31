// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Spec256 colour planes for the 128K banks the Layer 2 mirror has no room
// for, kept in DDR3 behind a small cache.
//
// The mirror holds the planes of banks 5, 2 and 0. A 128K game that colours
// other banks (Three Weeks in Paradise pages 3, 4 and 6 in at 0xC000, Head
// over Heels 1 and 7) has the rest here: one 64-bit word per address (plane
// k in bits 8k+7:8k), bank * 0x4000 + offset, at DDR3 beat BASE_BEAT +
// address / 4 (four words a beat, the first in bits 63:0).
//
// Reads: while lookup is high the CPUs are in a read of address in such a
// bank. A cache of 256 four-word lines (direct-mapped, 8 KiB of block RAM)
// answers a hit two cycles after the address arrives; read_data then holds
// the word for as long as the address stays. wait_request stays high until
// then, so the board holds the master, and with it every lane, through the
// core's WAIT, all nine in the same cycle. A miss fetches the line from DDR3
// (after any queued write) and fills it, a microsecond or so.
//
// Writes (write, one cycle, as the lanes or the loader write a word) go
// through to DDR3 from a queue of four, and into the cache when the line is
// there. A write arriving with the queue full is dropped and sets lost; the
// Z80 at 3.5 MHz writes at most once every three microseconds, and a DDR3
// write takes well under one. invalidate (the loader's H) drops every line.

`default_nettype none

module nexttang_spec256_plane_cache #(
    parameter integer BASE_BEAT = 'h30000
) (
    input  wire         clock,
    input  wire         reset,
    input  wire         invalidate,

    input  wire         lookup,
    input  wire [16:0]  address,
    output reg  [63:0]  read_data,
    output wire         wait_request,

    input  wire         write,
    input  wire [16:0]  write_address,
    input  wire [63:0]  write_data,
    output reg          lost,

    input  wire         memory_clock,
    input  wire         memory_reset,
    output wire         controller_request,
    input  wire         controller_command_ready,
    output wire [2:0]   controller_command,
    output wire         controller_command_enable,
    output wire [28:0]  controller_address,
    input  wire         controller_write_data_ready,
    output wire [255:0] controller_write_data,
    output wire         controller_write_data_enable,
    output wire         controller_write_data_end,
    output wire [31:0]  controller_write_data_mask,
    input  wire [255:0] controller_read_data,
    input  wire         controller_read_data_valid,
    output wire         controller_burst
);
    // Address: tag [16:10], line [9:2], word [1:0].
    reg [7:0]  tags [0:255];          // bit 7 valid, bits 6:0 tag
    reg [63:0] words [0:1023];
    reg [63:0] word_q;
    reg [16:0] address_d;
    reg        ready;
    reg [16:0] ready_address;

    // Set on the memory side, read across.
    reg         memory_write_ack = 1'b0;
    reg         memory_read_ack = 1'b0;
    reg [255:0] line_beat;

    // ------------------------------------------------------- machine side
    reg [2:0]   write_ack_sync = 3'b000;
    reg [2:0]   read_ack_sync = 3'b000;
    reg         write_request = 1'b0;
    reg         read_request = 1'b0;
    reg [16:0]  write_out_address;   // the write on its way to memory
    reg [63:0]  write_out_data;
    reg [16:0]  queue_address [0:3];
    reg [63:0]  queue_data [0:3];
    reg [2:0]   queue_count;
    reg [1:0]   queue_head;
    reg [14:0]  fetch_line;          // address[16:2] being fetched
    reg         fetching;
    reg         filling;
    reg [1:0]   fill_word;
    reg [8:0]   clearing;            // invalidate: one line a cycle
    reg         read_ok;             // word_q is the word for address_d

    wire write_free = write_request == write_ack_sync[2];
    wire read_done = read_request == read_ack_sync[2];
    wire [7:0] tag_d = tags[address_d[9:2]];
    wire hit_d = tag_d[7] && tag_d[6:0] == address_d[16:10];
    wire [7:0] write_tag = tags[write_address[9:2]];
    wire write_hit = write_tag[7] && write_tag[6:0] == write_address[16:10];

    assign wait_request = lookup && !(ready && ready_address == address);

    // The tags' one write port: clearing, or a filled line.
    wire       fill_done = filling && fill_word == 2'd3;
    wire       tag_write = clearing != 9'd0 || fill_done;
    wire [7:0] tag_index = clearing != 9'd0 ? clearing[7:0] - 8'd1 : fetch_line[7:0];
    wire [7:0] tag_value = clearing != 9'd0 ? 8'd0 : {1'b1, fetch_line[14:8]};
    always @(posedge clock)
        if (tag_write)
            tags[tag_index] <= tag_value;

    integer q;
    always @(posedge clock) begin
        write_ack_sync <= {write_ack_sync[1:0], memory_write_ack};
        read_ack_sync <= {read_ack_sync[1:0], memory_read_ack};
        address_d <= address;

        // The block RAM: a fill or a write, else the read for address.
        read_ok <= 1'b0;
        if (filling)
            words[{fetch_line[7:0], fill_word}] <= line_beat[64*fill_word +: 64];
        else if (write && write_hit)
            words[write_address[9:0]] <= write_data;
        else begin
            word_q <= words[address[9:0]];
            read_ok <= 1'b1;
        end

        // A read word is good when its address was looked up a cycle
        // before, the line was there, and nothing wrote the block RAM.
        ready <= 1'b0;
        if (read_ok && address_d == address && hit_d && !fetching && clearing == 9'd0) begin
            ready <= 1'b1;
            ready_address <= address_d;
            read_data <= word_q;
        end

        if (reset) begin
            lost <= 1'b0;
            queue_count <= 3'd0;
            queue_head <= 2'd0;
            fetching <= 1'b0;
            filling <= 1'b0;
            clearing <= 9'd256;
            ready <= 1'b0;
        end else begin
            if (invalidate) begin
                clearing <= 9'd256;
                ready <= 1'b0;
            end else if (clearing != 9'd0) begin
                clearing <= clearing - 9'd1;
            end

            // The queue: in at the tail, out at the head when the last
            // write has reached memory.
            if (write) begin
                if (queue_count == 3'd4) begin
                    lost <= 1'b1;
                end else begin
                    queue_address[queue_head + queue_count[1:0]] <= write_address;
                    queue_data[queue_head + queue_count[1:0]] <= write_data;
                end
            end
            if (queue_count != 3'd0 && write_free) begin
                write_out_address <= queue_address[queue_head];
                write_out_data <= queue_data[queue_head];
                write_request <= !write_request;
                queue_head <= queue_head + 2'd1;
                queue_count <= queue_count - 3'd1 + (write && queue_count != 3'd4);
            end else begin
                queue_count <= queue_count + (write && queue_count != 3'd4);
            end

            // A miss: fetch once every queued write is in memory, then fill.
            if (lookup && !fetching && !filling && clearing == 9'd0 &&
                address_d == address && !hit_d && !ready &&
                queue_count == 3'd0 && write_free && !write) begin
                fetching <= 1'b1;
                fetch_line <= address_d[16:2];
                read_request <= !read_request;
            end
            if (fetching && read_done) begin
                fetching <= 1'b0;
                filling <= 1'b1;
                fill_word <= 2'd0;
            end
            if (filling) begin
                fill_word <= fill_word + 2'd1;
                if (fill_word == 2'd3)
                    filling <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------- memory side
    reg [2:0]   write_request_sync = 3'b000;
    reg [2:0]   read_request_sync = 3'b000;

    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] WRITE = 2'd1;
    localparam [1:0] READ_COMMAND = 2'd2;
    localparam [1:0] READ_DATA = 2'd3;

    reg [1:0]   state;
    reg [14:0]  beat;
    reg [1:0]   word;

    wire [25:0] beat_address = BASE_BEAT + {11'd0, beat};
    wire write_pair_ready = controller_command_ready && controller_write_data_ready;

    assign controller_request = state == WRITE || state == READ_COMMAND;
    assign controller_command = state == WRITE ? 3'b000 : 3'b001;
    assign controller_command_enable = (state == WRITE && write_pair_ready) ||
                                       state == READ_COMMAND;
    assign controller_address = {beat_address, 3'b000};
    assign controller_write_data = {4{write_out_data}};
    assign controller_write_data_enable = state == WRITE && write_pair_ready;
    assign controller_write_data_end = 1'b1;
    assign controller_write_data_mask = ~(32'hff << {word, 3'b000});
    assign controller_burst = 1'b0;

    always @(posedge memory_clock or posedge memory_reset) begin
        if (memory_reset) begin
            state <= IDLE;
            write_request_sync <= 3'b000;
            read_request_sync <= 3'b000;
            memory_write_ack <= 1'b0;
            memory_read_ack <= 1'b0;
        end else begin
            write_request_sync <= {write_request_sync[1:0], write_request};
            read_request_sync <= {read_request_sync[1:0], read_request};

            case (state)
                IDLE: begin
                    // Writes first: a fetch waits for the queue anyway.
                    if (write_request_sync[2] != memory_write_ack) begin
                        beat <= write_out_address[16:2];
                        word <= write_out_address[1:0];
                        state <= WRITE;
                    end else if (read_request_sync[2] != memory_read_ack) begin
                        beat <= fetch_line;
                        state <= READ_COMMAND;
                    end
                end

                WRITE: begin
                    if (write_pair_ready) begin
                        memory_write_ack <= !memory_write_ack;
                        state <= IDLE;
                    end
                end

                READ_COMMAND: begin
                    if (controller_command_ready)
                        state <= READ_DATA;
                end

                READ_DATA: begin
                    if (controller_read_data_valid) begin
                        line_beat <= controller_read_data;
                        memory_read_ack <= !memory_read_ack;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
