// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// The RGB332 image is a 128 x 128 derivative of assets/brand/logo.png.

`default_nettype none

module nexttang_logo_rom #(
    parameter INITIALISATION_FILE = "rtl/smoke/nexttang_logo_128x128_rgb332.mem"
) (
    input  wire [13:0] address,
    output reg  [7:0]  rgb332
);
    reg [7:0] pixels [0:16383];

    initial begin
        $readmemh(INITIALISATION_FILE, pixels);
    end

    always @* begin
        rgb332 = pixels[address];
    end
endmodule

`default_nettype wire
