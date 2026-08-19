// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Fixed standard-ULA palette used until the full ZX Next palette memories are
// imported with the rest of the video pipeline.  zxula's standard mode places
// brightness in bit 3 and the Spectrum B/R/G colour bits in bits 0/1/2.  Higher
// bits distinguish palette banks and ink/paper entries, not their RGB value.

`default_nettype none

module nexttang_ula_palette (
    input  wire [7:0] palette_index,
    output wire [7:0] red,
    output wire [7:0] green,
    output wire [7:0] blue
);
    wire [7:0] intensity = palette_index[3] ? 8'hff : 8'hc0;

    assign red = palette_index[1] ? intensity : 8'h00;
    assign green = palette_index[2] ? intensity : 8'h00;
    assign blue = palette_index[0] ? intensity : 8'h00;
endmodule

`default_nettype wire
