// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_status_colour (
    input  wire [2:0]  status,
    output reg  [23:0] colour
);
    always @(*) begin
        case (status)
            3'd0: colour = 24'h003080;
            3'd1: colour = 24'hff8800;
            3'd2: colour = 24'h00a0c0;
            3'd3: colour = 24'h00b050;
            3'd4: colour = 24'hd00000;
            3'd5: colour = 24'ha000a0;
            3'd6: colour = 24'hffff00;
            default: colour = 24'h6000a0;
        endcase
    end
endmodule

`default_nettype wire
