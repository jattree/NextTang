// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Serve the ZXNext core's Layer 2 memory port from block RAM.
//
// Layer 2 registers a pixel address once per 7 MHz period and samples the byte
// four 28 MHz cycles later. DDR3 cannot answer in that time, so a block RAM
// keeps a copy of the parts of main memory Layer 2 is expected to use. Every
// write to main memory passes the core's port A on its way to DDR3; writes
// that land in a mirrored range are copied here as well, so the copy holds
// whatever the CPU or DMA last wrote. The write is repeated on every cycle of
// the core's memory request, so the byte kept is the one present when the
// request ends.
//
// Two ranges of 16 KiB SRAM units are mirrored, A and B, so a game can keep
// two Layer 2 screens apart, for example one in bank 8 and one in bank 18.
// Reads outside both return OUTSIDE. That byte is not reliably transparent:
// the core decides transparency after the palette, and in 640x256 each nibble
// is a pixel. The board therefore tells the core which units are mirrored, and
// the core hides Layer 2 everywhere else.

`default_nettype none

module nexttang_layer2_mirror #(
    // First unit and number of units of each range. SRAM unit = RAM bank + 16,
    // so unit 24 is bank 8. The ranges must not overlap and hold at most 16
    // units between them.
    parameter integer FIRST_A = 24,
    parameter integer BANKS_A = 5,
    parameter integer FIRST_B = 34,
    parameter integer BANKS_B = 5,
    parameter [7:0] OUTSIDE = 8'he3
) (
    input  wire        clock_28,

    input  wire        write_request,
    input  wire        write_n_read,
    input  wire [20:0] write_address,
    input  wire [7:0]  write_data,

    input  wire [20:0] read_address,
    output wire [7:0]  read_data,

    // The copy's byte for write_address as it was on the previous edge, and
    // whether that address is mirrored, for checking the copy against main
    // memory when it is read.
    output wire [7:0]  check_data,
    output reg         check_hit
);
    localparam integer UNITS = BANKS_A + BANKS_B;

    // Where a unit lives in the copy: range A first, then range B.
    function hit(input [6:0] unit);
        hit = (unit >= FIRST_A && unit < FIRST_A + BANKS_A) ||
              (unit >= FIRST_B && unit < FIRST_B + BANKS_B);
    endfunction

    function [3:0] slot(input [6:0] unit);
        slot = (unit >= FIRST_A && unit < FIRST_A + BANKS_A)
            ? unit - FIRST_A
            : BANKS_A + unit - FIRST_B;
    endfunction

    wire [6:0] write_unit = write_address[20:14];
    wire [6:0] read_unit = read_address[20:14];

    reg read_hit_q = 1'b0;
    initial check_hit = 1'b0;
    wire [7:0] mirror_data;

    always @(posedge clock_28) begin
        read_hit_q <= hit(read_unit);
        check_hit <= hit(write_unit);
    end

    nexttang_block_ram #(
        .ADDRESS_BITS(18),
        .DATA_BITS(8),
        .DEPTH(UNITS * 16384)
    ) mirror (
        .clock(clock_28),
        .write_enable(write_request && write_n_read && hit(write_unit)),
        .write_address({slot(write_unit), write_address[13:0]}),
        .write_data(write_data),
        .read_data(check_data),
        .port_b_clock(clock_28),
        .port_b_address({slot(read_unit), read_address[13:0]}),
        .port_b_data(mirror_data)
    );

    assign read_data = read_hit_q ? mirror_data : OUTSIDE;
endmodule

`default_nettype wire
