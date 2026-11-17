// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Feeds an RZX recording from a UART to the player
// (rtl/debug/nexttang_rzx_player.vhd), for boards whose only way in is the
// debug UART (docs/replay-and-rewind.md).
//
// The host has the machine paused at the recording's snapshot. It then
// sends, as single-letter-command bytes (command_valid / command_byte):
//
//     P n b1 .. bn    arm, and put n bytes (0 to 255) of the stream in the
//                     buffer ahead of time; only taken while the CPU is
//                     stopped
//
// and resumes the CPU. Playing starts at that resume, and from then on every
// received byte is stream, until playing ends. So the resume command must be
// the last byte of its debugger frame (X 01 A5): bytes of the same frame
// after it would already be taken as stream.
//
//     byte            a stream byte, except
//     FE 00           a stream byte FE
//     FE 01           end of stream: playing stops once the buffer is empty
//     FE 02           the same, and record_after is set: the board hands the
//                     machine to the RZX recorder at that moment and stops
//                     the CPU (a rewind: the host replays up to a frame and
//                     the recording carries on from there)
//
// The host ends the stream with the first three bytes of one more frame
// header (FF FF 00) and then FE 01: the player takes header bytes only when
// the frame before has ended, so the buffer is empty exactly when the last
// real frame is over, and by then the end is known, so playing stops on the
// spot with the CPU still held for the header. (A whole header before the
// end code left a gap: a replay of a frame or two could finish, take the
// header and run on before FE 01 arrived.)
//
// The stream is the player's: per frame, fetch count (2 bytes), IN count
// (2 bytes), the IN bytes. While `taking` is high the bytes are this
// module's and must be kept from every other command parser.
//
// To the host, on tx (valid while `busy`):
//
//     40..7F          frames have ended; the low six bits are the frame
//                     count so far (one byte can stand for several frames)
//     80 | flags, frames low, frames high
//                     playing has ended. flags bit 0: desync; bit 1: the
//                     buffer overflowed (bytes were lost); bit 2: the host
//                     ended the stream
//
// The frame bytes let the host pace itself: it knows each frame's size, so
// it knows how much of the buffer is free. The buffer holds 1 << FIFO_BITS
// bytes; a byte arriving when it is full is lost and reported.

`default_nettype none

module nexttang_rzx_play_link #(
    parameter integer CLOCK_HZ = 28000000,
    parameter integer BAUD_RATE = 115200,
    parameter FIFO_BITS = 10
) (
    input  wire       clock,
    input  wire       reset,

    input  wire       command_valid,
    input  wire [7:0] command_byte,
    output wire       taking,

    input  wire       cpu_stopped,

    // to and from the player
    output wire       play_start,
    output wire       play_stop,
    output reg        record_after = 1'b0,   // the stream ended with FE 02
    input  wire       playing,
    input  wire       desync,
    input  wire [15:0] frames,
    output wire [7:0] byte_out,
    output wire       byte_valid,
    input  wire       byte_ready,

    output wire       busy,
    output wire       tx
);
    localparam S_IDLE = 3'd0, S_COUNT = 3'd1, S_PREFILL = 3'd2, S_ARMED = 3'd3,
               S_STREAM = 3'd4, S_ESCAPE = 3'd5;
    reg [2:0] state = S_IDLE;
    reg [7:0] left = 8'd0;
    reg       stopped_q = 1'b0;
    reg       playing_q = 1'b0;
    reg       ending = 1'b0;       // the host has sent the end of the stream
    reg       overflow = 1'b0;
    reg       ended_by_host = 1'b0;
    reg       flush = 1'b0;

    assign taking = state == S_COUNT || state == S_PREFILL || state == S_STREAM || state == S_ESCAPE;
    wire resumed = stopped_q && !cpu_stopped;
    assign play_start = state == S_ARMED && resumed;

    // Buffer: block RAM with a one-byte output stage.
    localparam DEPTH = 1 << FIFO_BITS;
    reg [7:0] memory [0:DEPTH-1];
    reg [FIFO_BITS:0] wr_ptr = 0;
    reg [FIFO_BITS:0] rd_ptr = 0;
    wire empty = wr_ptr == rd_ptr;
    wire full = (wr_ptr[FIFO_BITS] != rd_ptr[FIFO_BITS]) &&
                (wr_ptr[FIFO_BITS-1:0] == rd_ptr[FIFO_BITS-1:0]);
    reg [7:0] read_data = 8'h00;
    reg       read_pending = 1'b0;   // read_data holds a byte next clock
    reg [7:0] out_data = 8'h00;
    reg       out_valid = 1'b0;
    assign byte_out = out_data;
    assign byte_valid = out_valid;
    wire out_take = out_valid && byte_ready;
    // Read the next byte when the output stage is, or is about to be, free.
    wire do_read = !empty && !read_pending && (!out_valid || out_take);

    reg       push = 1'b0;
    reg [7:0] push_data = 8'h00;

    // Stop: the host's end of stream, with everything taken by the player.
    wire drained = empty && !read_pending && !out_valid;
    assign play_stop = playing && ending && drained;

    // Transmitter: one byte at a time from a three-byte queue (the frame
    // byte, or the three end bytes).
    localparam integer BIT_CLOCKS_I = CLOCK_HZ / BAUD_RATE;
    localparam [15:0] BIT_CLOCKS = BIT_CLOCKS_I[15:0];
    reg [15:0] bit_timer = 16'd0;
    reg [3:0]  bits_left = 4'd0;
    reg [9:0]  shifter = 10'h3ff;
    reg [23:0] queue = 24'd0;
    reg [1:0]  queued = 2'd0;
    reg        frame_tick = 1'b0;
    reg [15:0] frames_q = 16'd0;
    reg        final_due = 1'b0;
    assign tx = shifter[0];
    assign busy = bits_left != 4'd0 || queued != 2'd0 || final_due || playing;

    always @(posedge clock) begin
        stopped_q <= cpu_stopped;
        playing_q <= playing;
        push <= 1'b0;
        flush <= 1'b0;

        // Received bytes.
        if (command_valid) begin
            case (state)
                S_IDLE, S_ARMED:
                    if (command_byte == "P" && cpu_stopped) begin
                        state <= S_COUNT;
                        flush <= 1'b1;
                    end
                S_COUNT: begin
                    left <= command_byte;
                    state <= command_byte == 8'd0 ? S_ARMED : S_PREFILL;
                end
                S_PREFILL: begin
                    push <= 1'b1;
                    push_data <= command_byte;
                    left <= left - 1'b1;
                    if (left == 8'd1)
                        state <= S_ARMED;
                end
                S_STREAM:
                    if (command_byte == 8'hfe)
                        state <= S_ESCAPE;
                    else begin
                        push <= 1'b1;
                        push_data <= command_byte;
                    end
                S_ESCAPE: begin
                    state <= S_STREAM;
                    if (command_byte == 8'h00) begin
                        push <= 1'b1;
                        push_data <= 8'hfe;
                    end else begin
                        ending <= 1'b1;
                        ended_by_host <= 1'b1;
                        record_after <= command_byte == 8'h02;
                    end
                end
                default: ;
            endcase
        end
        if (play_start)
            state <= S_STREAM;
        if (playing_q && !playing)
            state <= S_IDLE;

        // Buffer.
        if (push) begin
            if (full)
                overflow <= 1'b1;
            else begin
                memory[wr_ptr[FIFO_BITS-1:0]] <= push_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
        if (out_take)
            out_valid <= 1'b0;
        read_pending <= do_read;
        if (do_read) begin
            read_data <= memory[rd_ptr[FIFO_BITS-1:0]];
            rd_ptr <= rd_ptr + 1'b1;
        end
        if (read_pending) begin
            out_data <= read_data;
            out_valid <= 1'b1;
        end

        // To the host.
        frames_q <= frames;
        if (playing && frames != frames_q)
            frame_tick <= 1'b1;
        if (playing_q && !playing)
            final_due <= 1'b1;
        if (bits_left != 4'd0) begin
            if (bit_timer == 16'd0) begin
                shifter <= {1'b1, shifter[9:1]};
                bits_left <= bits_left - 1'b1;
                bit_timer <= BIT_CLOCKS - 1'b1;
            end else
                bit_timer <= bit_timer - 1'b1;
        end else if (queued != 2'd0) begin
            shifter <= {1'b1, queue[7:0], 1'b0};
            queue <= {8'h00, queue[23:8]};
            queued <= queued - 1'b1;
            bits_left <= 4'd10;
            bit_timer <= BIT_CLOCKS - 1'b1;
        end else if (final_due) begin
            queue <= {frames[15:8], frames[7:0], 5'b10000, ended_by_host, overflow, desync};
            queued <= 2'd3;
            final_due <= 1'b0;
        end else if (frame_tick) begin
            queue <= {16'h0000, 2'b01, frames[5:0]};
            queued <= 2'd1;
            frame_tick <= 1'b0;
        end

        // A new P empties the buffer (after the logic above, which it overrides).
        if (flush) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            out_valid <= 1'b0;
            read_pending <= 1'b0;
            ending <= 1'b0;
            overflow <= 1'b0;
            ended_by_host <= 1'b0;
            record_after <= 1'b0;
            frame_tick <= 1'b0;
        end

        if (reset) begin
            state <= S_IDLE;
            wr_ptr <= 0;
            rd_ptr <= 0;
            out_valid <= 1'b0;
            read_pending <= 1'b0;
            push <= 1'b0;
            flush <= 1'b0;
            ending <= 1'b0;
            overflow <= 1'b0;
            ended_by_host <= 1'b0;
            record_after <= 1'b0;
            stopped_q <= 1'b0;
            playing_q <= 1'b0;
            bits_left <= 4'd0;
            queued <= 2'd0;
            final_due <= 1'b0;
            frame_tick <= 1'b0;
            shifter <= 10'h3ff;
        end
    end
endmodule

`default_nettype wire
