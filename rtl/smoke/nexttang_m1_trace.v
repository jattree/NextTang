// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Instruction-fetch history for debugging software that goes wrong on the
// board.
//
// Every opcode fetch (the falling edge of M1) from a different address than
// the last one recorded writes its address into a ring. A halted CPU keeps
// fetching at one address, and recording each of those would fill the ring
// with the HALT in a few milliseconds. The ring is
// 2^DEPTH_BITS entries. The first fetch from TRIGGER_ADDRESS arms a
// countdown of POST_FETCHES more, after which the ring freezes, holding what
// led up to the trigger and a little of what followed. The default trigger is
// 0x0066, the NMI entry, which is where NextZXOS goes when it traps an access
// to hardware the Next does not have.
//
// Once frozen, the ring is sent over the UART oldest first as lines of
//
//     TR aaaa
//
// ending with "TE", and sent again after a gap, so a host that starts
// listening late still gets a whole copy. `frozen` lets the board hand the
// UART pin over from the status reporter.
//
// The host can also freeze the ring at once with `freeze_request`, and
// `rearm_request` unfreezes it and waits for the trigger again, so several
// captures can be taken from one load. `set_trigger` replaces the trigger
// address with `new_trigger` and re-arms.

`default_nettype none

module nexttang_m1_trace #(
    parameter integer CLOCK_HZ = 28000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer DEPTH_BITS = 12,
    parameter integer POST_FETCHES = 64,
    parameter [15:0] TRIGGER_ADDRESS = 16'h0066,
    parameter integer GAP_CLOCKS = 28000000
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        m1_n,
    input  wire [15:0] address,
    input  wire        freeze_request,
    input  wire        rearm_request,
    input  wire        set_trigger,
    input  wire [15:0] new_trigger,
    output reg         frozen,
    output reg         transmit
);
    localparam integer DEPTH = 1 << DEPTH_BITS;

    reg [15:0] ring [0:DEPTH-1];
    reg [DEPTH_BITS-1:0] write_pointer = 0;
    reg m1_previous = 1'b1;
    reg armed = 1'b0;
    reg [15:0] post_left = 0;
    reg [15:0] trigger_address = TRIGGER_ADDRESS;
    reg [15:0] last_recorded = 16'hffff;

    wire fetch = m1_previous && !m1_n && address != last_recorded;

    always @(posedge clock) begin
        if (reset) begin
            write_pointer <= 0;
            m1_previous <= 1'b1;
            armed <= 1'b0;
            post_left <= 0;
            frozen <= 1'b0;
            trigger_address <= TRIGGER_ADDRESS;
        end else if (rearm_request || set_trigger) begin
            if (set_trigger)
                trigger_address <= new_trigger;
            m1_previous <= m1_n;
            armed <= 1'b0;
            post_left <= 0;
            frozen <= 1'b0;
        end else if (freeze_request) begin
            m1_previous <= m1_n;
            frozen <= 1'b1;
        end else begin
            m1_previous <= m1_n;
            if (fetch && !frozen) begin
                write_pointer <= write_pointer + 1'b1;
                last_recorded <= address;
                if (!armed && address == trigger_address) begin
                    armed <= 1'b1;
                    post_left <= POST_FETCHES;
                end else if (armed) begin
                    if (post_left == 0)
                        frozen <= 1'b1;
                    else
                        post_left <= post_left - 1'b1;
                end
            end
        end
    end

    always @(posedge clock)
        if (fetch && !frozen && !reset)
            ring[write_pointer] <= address;

    // ------------------------------------------------------------- dump
    function [7:0] hex_digit(input [3:0] value);
        hex_digit = (value < 10) ? ("0" + value) : ("a" + value - 10);
    endfunction

    reg [DEPTH_BITS-1:0] read_pointer = 0;
    reg [DEPTH_BITS:0] entries_left = 0;
    reg [15:0] entry = 0;
    reg [3:0] byte_index = 0;
    reg [9:0] shifter = 10'h3ff;
    reg [3:0] bit_index = 0;
    reg [31:0] baud_accumulator = 0;
    reg [31:0] gap_counter = 0;
    reg sending_byte = 1'b0;
    reg [1:0] phase = 0;            // 0 idle, 1 fetch entry, 2 send line, 3 send end

    always @(posedge clock)
        entry <= ring[read_pointer];

    function [7:0] line_byte(input [3:0] index, input [15:0] value);
        case (index)
            4'd0: line_byte = "T";
            4'd1: line_byte = "R";
            4'd2: line_byte = " ";
            4'd3: line_byte = hex_digit(value[15:12]);
            4'd4: line_byte = hex_digit(value[11:8]);
            4'd5: line_byte = hex_digit(value[7:4]);
            4'd6: line_byte = hex_digit(value[3:0]);
            4'd7: line_byte = 8'h0d;
            default: line_byte = 8'h0a;
        endcase
    endfunction

    function [7:0] end_byte(input [3:0] index);
        case (index)
            4'd0: end_byte = "T";
            4'd1: end_byte = "E";
            4'd2: end_byte = 8'h0d;
            default: end_byte = 8'h0a;
        endcase
    endfunction

    always @(posedge clock) begin
        if (reset || !frozen) begin
            transmit <= 1'b1;
            phase <= 0;
            sending_byte <= 1'b0;
            gap_counter <= 0;
            bit_index <= 0;
            baud_accumulator <= 0;
        end else if (sending_byte) begin
            baud_accumulator <= baud_accumulator + BAUD_RATE;
            if (baud_accumulator + BAUD_RATE >= CLOCK_HZ) begin
                baud_accumulator <= baud_accumulator + BAUD_RATE - CLOCK_HZ;
                transmit <= shifter[0];
                shifter <= {1'b1, shifter[9:1]};
                if (bit_index == 9) begin
                    bit_index <= 0;
                    sending_byte <= 1'b0;
                end else begin
                    bit_index <= bit_index + 1'b1;
                end
            end
        end else begin
            case (phase)
                2'd0: begin
                    transmit <= 1'b1;
                    if (gap_counter == GAP_CLOCKS - 1) begin
                        gap_counter <= 0;
                        // Oldest entry first: the one the next write would replace.
                        read_pointer <= write_pointer;
                        entries_left <= DEPTH;
                        phase <= 2'd1;
                    end else begin
                        gap_counter <= gap_counter + 1'b1;
                    end
                end
                2'd1: begin
                    // The ring read has a cycle of latency; wait one here.
                    byte_index <= 0;
                    phase <= 2'd2;
                end
                2'd2: begin
                    shifter <= {1'b1, line_byte(byte_index, entry), 1'b0};
                    sending_byte <= 1'b1;
                    if (byte_index == 4'd8) begin
                        read_pointer <= read_pointer + 1'b1;
                        entries_left <= entries_left - 1'b1;
                        if (entries_left == 1) begin
                            byte_index <= 0;
                            phase <= 2'd3;
                        end else begin
                            phase <= 2'd1;
                        end
                    end else begin
                        byte_index <= byte_index + 1'b1;
                    end
                end
                2'd3: begin
                    shifter <= {1'b1, end_byte(byte_index), 1'b0};
                    sending_byte <= 1'b1;
                    if (byte_index == 4'd3)
                        phase <= 2'd0;
                    else
                        byte_index <= byte_index + 1'b1;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
