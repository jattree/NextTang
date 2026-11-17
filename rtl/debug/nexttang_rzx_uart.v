// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Sends the RZX recorder's words (rtl/debug/nexttang_rzx_logger.v) over a
// UART, for boards that keep no recording in memory (the Nano 20K, whose
// debug UART reaches the host). host/rzx_capture.py reads it.
//
// On the line:
//
//     "RZX!"                      at begin_stream
//     b                           an IN byte below 0xFD
//     0xFE b                      an IN byte of 0xFD, 0xFE or 0xFF
//     0xFF lo hi                  a frame end and its fetch count
//     0xFD flags frames_lo frames_hi
//                                 at end_stream, once every word is sent:
//                                 flags bit 0 the count saturated, bit 1 the
//                                 recorder's FIFO overflowed (either spoils
//                                 the recording)
//
// A frame end arrives as two tagged words (low byte, high byte); 0xFF goes
// before the first. busy is high from begin_stream until the end is sent, so
// a board can give this module the transmit line for that long. The line is
// held idle for LEAD_BITS bit times before "RZX!", so a byte another sender
// was part-way through when the board switched the line over cannot run into
// the marker; words wait in the recorder's FIFO meanwhile.

`default_nettype none

module nexttang_rzx_uart #(
    parameter integer CLOCK_HZ = 28000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer LEAD_BITS = 30
) (
    input  wire       clock,
    input  wire       reset,

    input  wire       begin_stream,
    input  wire       end_stream,
    input  wire [1:0] end_flags,
    input  wire [15:0] end_frames,

    input  wire [8:0] word,
    input  wire       word_valid,
    output wire       word_ready,

    output reg        busy = 1'b0,
    output reg        tx = 1'b1
);
    localparam integer BIT_CLOCKS_I = CLOCK_HZ / BAUD_RATE;
    // counters only as wide as their limits (16 and 24 bits before 2026-11-17: the unused bits were built)
    localparam integer BIT_W = $clog2(BIT_CLOCKS_I);
    localparam [BIT_W-1:0] BIT_LAST = BIT_CLOCKS_I - 1;

    // transmitter: one byte at a time
    reg [9:0]  shift = 10'h3ff;
    reg [3:0]  bits_left = 4'd0;
    reg [BIT_W-1:0] timer = {BIT_W{1'b0}};
    wire       tx_idle = bits_left == 4'd0;
    reg        send;
    reg [7:0]  send_byte;

    // what goes next
    localparam S_IDLE = 3'd0, S_HEAD = 3'd1, S_WORDS = 3'd2, S_RAW = 3'd3, S_TAIL = 3'd4, S_LEAD = 3'd5;
    localparam integer LEAD_CLOCKS = BIT_CLOCKS_I * LEAD_BITS;
    localparam integer LEAD_W = $clog2(LEAD_CLOCKS + 1);
    localparam [LEAD_W-1:0] LEAD_FIRST = LEAD_CLOCKS;
    reg [LEAD_W-1:0] lead = {LEAD_W{1'b0}};
    reg [2:0]  state = S_IDLE;
    reg [1:0]  index = 2'd0;          // byte within the header or tail
    reg [7:0]  raw_byte = 8'h00;      // a byte to send after its marker
    reg        tag_pending = 1'b0;    // the next tagged word is a frame end's high byte
    reg        ending = 1'b0;
    reg [1:0]  flags = 2'b00;
    reg [15:0] frames = 16'd0;

    assign word_ready = state == S_WORDS && tx_idle && word_valid;

    always @* begin
        send = 1'b0;
        send_byte = 8'h00;
        if (tx_idle) begin
            case (state)
                S_HEAD: begin
                    send = 1'b1;
                    send_byte = index == 2'd0 ? "R" : index == 2'd1 ? "Z" : index == 2'd2 ? "X" : "!";
                end
                S_WORDS:
                    if (word_valid) begin
                        send = 1'b1;
                        if (word[8])
                            send_byte = tag_pending ? word[7:0] : 8'hff;
                        else
                            send_byte = word[7:0] >= 8'hfd ? 8'hfe : word[7:0];
                    end
                S_RAW: begin
                    send = 1'b1;
                    send_byte = raw_byte;
                end
                S_TAIL: begin
                    send = 1'b1;
                    send_byte = index == 2'd0 ? 8'hfd : index == 2'd1 ? {6'd0, flags}
                              : index == 2'd2 ? frames[7:0] : frames[15:8];
                end
                default: ;
            endcase
        end
    end

    always @(posedge clock) begin
        if (send) begin
            shift <= {1'b1, send_byte, 1'b0};
            bits_left <= 4'd10;
            timer <= BIT_LAST;
        end else if (!tx_idle) begin
            if (timer == {BIT_W{1'b0}}) begin
                shift <= {1'b1, shift[9:1]};
                bits_left <= bits_left - 4'd1;
                timer <= BIT_LAST;
            end else
                timer <= timer - 1'b1;
        end
        tx <= tx_idle ? 1'b1 : shift[0];

        if (end_stream) begin
            ending <= 1'b1;
            flags <= end_flags;
            frames <= end_frames;
        end

        case (state)
            S_LEAD:
                if (lead == {LEAD_W{1'b0}}) state <= S_HEAD;
                else lead <= lead - 1'b1;
            S_HEAD:
                if (send) begin
                    index <= index + 2'd1;
                    if (index == 2'd3) state <= S_WORDS;
                end
            S_WORDS:
                if (send) begin
                    if (word[8]) begin
                        // first tagged word: 0xFF now, the low byte next
                        if (!tag_pending) begin
                            raw_byte <= word[7:0];
                            state <= S_RAW;
                        end
                        tag_pending <= !tag_pending;
                    end else if (word[7:0] >= 8'hfd) begin
                        raw_byte <= word[7:0];
                        state <= S_RAW;
                    end
                end else if (tx_idle && !word_valid && ending) begin
                    index <= 2'd0;
                    state <= S_TAIL;
                end
            S_RAW:
                if (send) state <= S_WORDS;
            S_TAIL:
                if (send) begin
                    index <= index + 2'd1;
                    if (index == 2'd3) state <= S_IDLE;
                end
            default: ;
        endcase

        if (state == S_IDLE && tx_idle)
            busy <= 1'b0;
        if (begin_stream) begin
            state <= S_LEAD;
            lead <= LEAD_FIRST;
            index <= 2'd0;
            tag_pending <= 1'b0;
            ending <= 1'b0;
            busy <= 1'b1;
        end
        if (reset) begin
            state <= S_IDLE;
            busy <= 1'b0;
            bits_left <= 4'd0;
            ending <= 1'b0;
            tag_pending <= 1'b0;
        end
    end
endmodule

`default_nettype wire
