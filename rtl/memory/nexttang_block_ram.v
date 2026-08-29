// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Block RAM with a read/write port and an independent read port.
//
// The read port returns the stored value and does not forward a write
// happening at the same address on the same cycle. That is the one behaviour
// this device's block RAM supports in every configuration: read-first
// forwarding is unavailable when the tool collapses an unused second port and
// maps the memory as single-port, which it does whenever port B is tied off.
//
// No forwarding is required here. The Z80 never reads an address in the same
// cycle it writes it, and the display reads a frame behind whatever the
// processor is drawing.
//
// The two ports have independent clocks so video can read screen memory at the
// pixel rate while the processor writes it at its own much slower rate. Reads
// are unsynchronised by design: a read that lands on the same address as a
// write returns the old or new byte, and either is a pixel the display was
// entitled to draw this frame.

`default_nettype none

module nexttang_block_ram #(
    parameter integer ADDRESS_BITS = 13,
    parameter integer DATA_BITS = 8,
    parameter IMAGE = ""
) (
    input  wire                     clock,

    input  wire                     write_enable,
    input  wire [ADDRESS_BITS-1:0]  write_address,
    input  wire [DATA_BITS-1:0]     write_data,
    output reg  [DATA_BITS-1:0]     read_data,

    input  wire                     port_b_clock,
    input  wire [ADDRESS_BITS-1:0]  port_b_address,
    output reg  [DATA_BITS-1:0]     port_b_data
);
    localparam integer DEPTH = 1 << ADDRESS_BITS;

    reg [DATA_BITS-1:0] storage [0:DEPTH-1];

    initial begin
        if (IMAGE != "")
            $readmemh(IMAGE, storage);
    end

    always @(posedge clock) begin
        if (write_enable)
            storage[write_address] <= write_data;
        else
            read_data <= storage[write_address];
    end

    always @(posedge port_b_clock) begin
        port_b_data <= storage[port_b_address];
    end
endmodule

`default_nettype wire
