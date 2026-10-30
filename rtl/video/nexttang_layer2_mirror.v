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
// Up to two ranges of 16 KiB SRAM units are mirrored, A and B, so a copy can
// cover two places a game keeps Layer 2 screens without the banks between.
//
// The copy is eight byte-wide memories side by side: byte o of the copy is
// in memory o mod 8, at word o / 8. With 24 units (384 KiB) the same storage
// holds Spec256's eight colour planes for a 48K game, 0x4000 to 0xFFFF, one
// plane per memory: Spectrum address x is word x - 0x4000 in all eight, so
// one access reaches every plane. A 48K Spec256 game has no Layer 2, so in
// spec256_mode the lanes take port A, which the CPU's writes otherwise use,
// and the colour overlay takes port B, which Layer 2 otherwise reads.
// Reads outside both return OUTSIDE. That byte is not reliably transparent:
// the core decides transparency after the palette, and in 640x256 each nibble
// is a pixel. The board therefore tells the core which units are mirrored, and
// the core hides Layer 2 everywhere else.

`default_nettype none

module nexttang_layer2_mirror #(
    // First unit and number of units of each range. SRAM unit = RAM bank + 16,
    // so unit 24 is bank 8. The ranges must not overlap; B may be empty.
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
    output reg         check_hit,

    // Spec256: the lanes on port A, the overlay on port B, both by Spectrum
    // address (0x4000 to 0xFFFF), lane k's byte in bits 8k+7:8k. Reads return
    // the word at the address of the previous edge.
    input  wire        spec256_mode,
    input  wire [15:0] lane_address,
    input  wire        lane_write,
    input  wire [63:0] lane_write_data,
    output wire [63:0] lane_read_data,
    input  wire [15:0] overlay_address,
    output wire [63:0] overlay_data
);
    localparam integer UNITS = BANKS_A + BANKS_B;
    localparam integer SLOT_BITS = UNITS > 1 ? $clog2(UNITS) : 1;
    localparam integer WORDS = UNITS * 2048;
    localparam integer WORD_BITS = $clog2(WORDS);

    initial begin
        if (UNITS < 24)
            $display("nexttang_layer2_mirror: fewer than 24 units, no room for Spec256 planes");
    end

    // Where a unit lives in the copy: range A first, then range B.
    function hit(input [6:0] unit);
        hit = (unit >= FIRST_A && unit < FIRST_A + BANKS_A) ||
              (unit >= FIRST_B && unit < FIRST_B + BANKS_B);
    endfunction

    function [SLOT_BITS-1:0] slot(input [6:0] unit);
        slot = (unit >= FIRST_A && unit < FIRST_A + BANKS_A)
            ? unit - FIRST_A
            : BANKS_A + unit - FIRST_B;
    endfunction

    wire [6:0] write_unit = write_address[20:14];
    wire [6:0] read_unit = read_address[20:14];

    // Copy word and memory for a Layer 2 address; Spectrum word for a plane.
    wire [WORD_BITS-1:0] write_word = {slot(write_unit), write_address[13:3]};
    wire [WORD_BITS-1:0] read_word = {slot(read_unit), read_address[13:3]};
    wire [WORD_BITS-1:0] lane_word = lane_address - 16'h4000;
    wire [WORD_BITS-1:0] overlay_word = overlay_address - 16'h4000;
    wire lane_in_planes = lane_address[15:14] != 2'b00;

    reg read_hit_q = 1'b0;
    reg [2:0] read_byte_q = 3'd0;
    reg [2:0] check_byte_q = 3'd0;
    initial check_hit = 1'b0;

    always @(posedge clock_28) begin
        read_hit_q <= hit(read_unit);
        read_byte_q <= read_address[2:0];
        check_hit <= hit(write_unit);
        check_byte_q <= write_address[2:0];
    end

    wire [63:0] port_a_data;
    wire [63:0] port_b_data;

    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : memory
            wire layer2_write = write_request && write_n_read && hit(write_unit) &&
                                write_address[2:0] == k;
            nexttang_block_ram #(
                .ADDRESS_BITS(WORD_BITS),
                .DATA_BITS(8),
                .DEPTH(WORDS)
            ) bytes (
                .clock(clock_28),
                .write_enable(spec256_mode ? lane_write && lane_in_planes : layer2_write),
                .write_address(spec256_mode ? lane_word : write_word),
                .write_data(spec256_mode ? lane_write_data[8*k +: 8] : write_data),
                .read_data(port_a_data[8*k +: 8]),
                .port_b_clock(clock_28),
                .port_b_address(spec256_mode ? overlay_word : read_word),
                .port_b_data(port_b_data[8*k +: 8])
            );
        end
    endgenerate

    assign read_data = read_hit_q ? port_b_data[8*read_byte_q +: 8] : OUTSIDE;
    assign check_data = port_a_data[8*check_byte_q +: 8];
    assign lane_read_data = port_a_data;
    assign overlay_data = port_b_data;
endmodule

`default_nettype wire
