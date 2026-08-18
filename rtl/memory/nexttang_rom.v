// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Read-only memory initialised from a hex image at synthesis time.
//
// The image is named rather than embedded because machine ROMs are not
// redistributable. The build writes one into its own directory from a file the
// user supplies, so nothing derived from a ROM is ever committed.

`default_nettype none

module nexttang_rom #(
    parameter integer ADDRESS_BITS = 14,
    parameter integer DATA_BITS = 8,
    parameter IMAGE = ""
) (
    input  wire                    clock,
    input  wire [ADDRESS_BITS-1:0] address,
    output reg  [DATA_BITS-1:0]    data
);
    localparam integer DEPTH = 1 << ADDRESS_BITS;

    reg [DATA_BITS-1:0] storage [0:DEPTH-1];

    initial begin
        if (IMAGE == "")
            $fatal(1, "nexttang_rom needs an IMAGE");
        $readmemh(IMAGE, storage);
    end

    always @(posedge clock) begin
        data <= storage[address];
    end
endmodule

`default_nettype wire
