// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_spec256_palette #(
    parameter IMAGE = "spec256-palette.mem"
) (
    input  wire       clock,
    input  wire       write_enable,
    input  wire [7:0] write_index,
    input  wire [23:0] write_data,
    input  wire [7:0] index,
    output wire [7:0] red,
    output wire [7:0] green,
    output wire [7:0] blue
);
    reg [23:0] colours [0:255];

    initial begin
        if (IMAGE != "")
            $readmemh(IMAGE, colours);
    end

    always @(posedge clock)
        if (write_enable)
            colours[write_index] <= write_data;

    assign {red, green, blue} = colours[index];
endmodule

`default_nettype wire
