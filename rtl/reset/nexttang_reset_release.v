// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_reset_release #(
    parameter integer STAGES = 4
) (
    input  wire clock,
    input  wire asynchronous_reset,
    output wire reset
);
    reg [STAGES-1:0] release_shift = {STAGES{1'b1}};

    always @(posedge clock or posedge asynchronous_reset) begin
        if (asynchronous_reset)
            release_shift <= {STAGES{1'b1}};
        else
            release_shift <= release_shift << 1;
    end

    assign reset = release_shift[STAGES-1];
endmodule

`default_nettype wire
