// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
`default_nettype none

// Loader-only palette implementation that preserves the palette contract while
// leaving BSRAM headroom. The hardware-verified UART runtime retains the
// original BSRAM-inferred palette module.
module nexttang_spec256_palette_distributed #(
    parameter IMAGE = ""
) (
    input wire clock,input wire write_enable,input wire[7:0]write_index,
    input wire[23:0]write_data,input wire[7:0]index,
    output wire[7:0]red,green,blue);
    (* syn_ramstyle = "distributed_ram" *) reg[23:0]colours[0:255];
    initial if(IMAGE!="")$readmemh(IMAGE,colours);
    always@(posedge clock)if(write_enable)colours[write_index]<=write_data;
    assign{red,green,blue}=colours[index];
endmodule
`default_nettype wire
