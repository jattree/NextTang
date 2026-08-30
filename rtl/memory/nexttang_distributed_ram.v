// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
`default_nettype none

// Synchronous single-port byte RAM explicitly implemented in distributed
// SRAM. Used sparingly where the DDR3 interface and Spec256 BSRAM footprint
// otherwise exceed the exact C device.
module nexttang_distributed_ram #(
    parameter integer ADDRESS_BITS = 14
) (
    input  wire                    clock,
    input  wire                    write_enable,
    input  wire [ADDRESS_BITS-1:0] address,
    input  wire [7:0]              write_data,
    output reg  [7:0]              read_data
);
    (* syn_ramstyle = "distributed_ram" *)
    reg [7:0] storage [0:(1 << ADDRESS_BITS)-1];
    always @(posedge clock) begin
        if (write_enable)
            storage[address] <= write_data;
        read_data <= storage[address];
    end
endmodule

`default_nettype wire
