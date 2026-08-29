// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A byte-wide 48K Spectrum RAM composed from three 16K block-RAM banks.
// Full machine addresses are accepted at both ports.

`default_nettype none

module nexttang_spectrum_ram #(
    parameter IMAGE_0 = "",
    parameter IMAGE_1 = "",
    parameter IMAGE_2 = ""
) (
    input  wire        clock,
    input  wire        write_enable,
    input  wire [15:0] write_address,
    input  wire [7:0]  write_data,
    output wire [7:0]  read_data,

    input  wire        port_b_clock,
    input  wire [15:0] port_b_address,
    output wire [7:0]  port_b_data
);
    wire [7:0] read_bank_0, read_bank_1, read_bank_2;
    wire [7:0] display_bank_0, display_bank_1, display_bank_2;
    reg [1:0] read_bank = 2'b01;
    reg [1:0] display_bank = 2'b01;

    always @(posedge clock)
        read_bank <= write_address[15:14];

    always @(posedge port_b_clock)
        display_bank <= port_b_address[15:14];

    assign read_data = read_bank == 2'b01 ? read_bank_0 :
                       read_bank == 2'b10 ? read_bank_1 :
                       read_bank == 2'b11 ? read_bank_2 : 8'hff;
    assign port_b_data = display_bank == 2'b01 ? display_bank_0 :
                         display_bank == 2'b10 ? display_bank_1 :
                         display_bank == 2'b11 ? display_bank_2 : 8'hff;

    nexttang_block_ram #(.ADDRESS_BITS(14), .IMAGE(IMAGE_0)) bank_0 (
        .clock(clock),
        .write_enable(write_enable && write_address[15:14] == 2'b01),
        .write_address(write_address[13:0]),
        .write_data(write_data),
        .read_data(read_bank_0),
        .port_b_clock(port_b_clock),
        .port_b_address(port_b_address[13:0]),
        .port_b_data(display_bank_0)
    );

    nexttang_block_ram #(.ADDRESS_BITS(14), .IMAGE(IMAGE_1)) bank_1 (
        .clock(clock),
        .write_enable(write_enable && write_address[15:14] == 2'b10),
        .write_address(write_address[13:0]),
        .write_data(write_data),
        .read_data(read_bank_1),
        .port_b_clock(port_b_clock),
        .port_b_address(port_b_address[13:0]),
        .port_b_data(display_bank_1)
    );

    nexttang_block_ram #(.ADDRESS_BITS(14), .IMAGE(IMAGE_2)) bank_2 (
        .clock(clock),
        .write_enable(write_enable && write_address[15:14] == 2'b11),
        .write_address(write_address[13:0]),
        .write_data(write_data),
        .read_data(read_bank_2),
        .port_b_clock(port_b_clock),
        .port_b_address(port_b_address[13:0]),
        .port_b_data(display_bank_2)
    );
endmodule

`default_nettype wire
