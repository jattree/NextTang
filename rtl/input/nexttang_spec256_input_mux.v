// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Read-data selection for one graphical Spec256 CPU. Each graphical lane has
// its own address and bus cycle, so an I/O read must be decoded from that
// lane's address rather than borrowing the ordinary CPU's already-decoded
// input. The physical keyboard and tape state remain shared by all contexts.

`default_nettype none

module nexttang_spec256_input_mux (
    input  wire [15:0] address,
    input  wire        io_request,
    input  wire [39:0] keys,
    input  wire [4:0]  joystick,
    input  wire        tape_ear,
    input  wire [7:0]  rom_data,
    input  wire [7:0]  ram_data,
    output wire [7:0]  data
);
    wire [4:0] key_columns;
    wire in_rom = address[15:14] == 2'b00;
    wire port_fe = !address[0];
    wire port_kempston = address[7:0] == 8'h1f;

    nexttang_keyboard_matrix keyboard (
        .row_select(address[15:8]),
        .keys(keys),
        .columns(key_columns)
    );

    assign data = io_request
        ? (port_fe ? {1'b1, tape_ear, 1'b1, key_columns} :
           port_kempston ? {3'b000, joystick} : 8'hff)
        : (in_rom ? rom_data : ram_data);
endmodule

`default_nettype wire
