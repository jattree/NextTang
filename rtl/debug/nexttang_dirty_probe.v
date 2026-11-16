// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// How much memory a program writes, measured on the board, to size the
// rewind ring's checkpoints (docs/replay-and-rewind.md, piece 4).
//
// Holds the dirty-block tracker (nexttang_dirty_blocks: a bit per 256 bytes
// of the 2 MB) on the CPU's memory writes. On `request` it scans the
// tracker, taking and so clearing every dirty block, and sends one line:
//
//     d NNNN \n       (hex, no spaces) the number of blocks written since
//                     the last request (2000 = all 8,192, as after reset)
//
// So a host that asks once a second reads the blocks a checkpoint a second
// would have to copy. A diagnostic: nothing is copied anywhere.

`default_nettype none

module nexttang_dirty_probe #(
    parameter integer CLOCK_HZ = 28125000,
    parameter integer BAUD_RATE = 115200
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        request,

    input  wire        write_valid,     // one clock per byte written to main memory
    input  wire [20:0] write_address,

    output wire        tx
);
    wire        block_valid, scan_done, scanning;
    wire [12:0] block;
    reg  [13:0] count = 14'd0;

    nexttang_dirty_blocks #(.BLOCK_BITS(13)) tracker (
        .clock(clock), .reset(reset),
        .write_valid_in(write_valid), .write_block_in(write_address[20:8]),
        .scan_start(request && !scanning),
        .block_valid(block_valid), .block(block), .block_ready(1'b1),
        .scan_done(scan_done), .scanning(scanning));

    function [7:0] hex(input [3:0] n);
        hex = n < 4'd10 ? 8'h30 + {4'd0, n} : 8'h37 + {4'd0, n};
    endfunction

    localparam integer BIT_CLOCKS = CLOCK_HZ / BAUD_RATE;
    reg [47:0] line = 48'd0;
    reg [2:0]  left = 3'd0;
    reg [15:0] baud = 16'd0;
    reg [3:0]  bits = 4'd0;
    reg [9:0]  shift = 10'h3ff;
    wire [13:0] total = count + (block_valid ? 14'd1 : 14'd0);
    always @(posedge clock) begin
        if (request && !scanning)
            count <= 14'd0;
        else if (block_valid)
            count <= count + 14'd1;

        if (bits != 4'd0) begin
            if (baud == 16'd0) begin
                shift <= {1'b1, shift[9:1]};
                bits <= bits - 4'd1;
                baud <= BIT_CLOCKS[15:0] - 16'd1;
            end else
                baud <= baud - 16'd1;
        end else if (left != 3'd0) begin
            shift <= {1'b1, line[47:40], 1'b0};
            line <= {line[39:0], 8'h00};
            left <= left - 3'd1;
            bits <= 4'd10;
            baud <= BIT_CLOCKS[15:0] - 16'd1;
        end
        if (scan_done) begin
            line <= {"d", hex({2'b00, total[13:12]}), hex(total[11:8]), hex(total[7:4]), hex(total[3:0]), 8'h0a};
            left <= 3'd6;
        end
        if (reset) begin
            left <= 3'd0;
            bits <= 4'd0;
            shift <= 10'h3ff;
            count <= 14'd0;
        end
    end
    assign tx = shift[0];
endmodule

`default_nettype wire
