// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Present the USB host's normalized gamepad controls as a Kempston joystick.
// Port 0x1f uses bit 0 right, bit 1 left, bit 2 down, bit 3 up and bit 4 fire.

`default_nettype none

module nexttang_usb_gamepad_kempston (
    input  wire [1:0] device_type,
    input  wire       left,
    input  wire       right,
    input  wire       up,
    input  wire       down,
    input  wire       a,
    input  wire       b,
    input  wire       x,
    input  wire       y,
    output wire [4:0] joystick
);
    localparam [1:0] TYPE_GAMEPAD = 2'd3;

    wire fire = a | b | x | y;
    assign joystick = device_type == TYPE_GAMEPAD
        ? {fire, up, down, left, right} : 5'b00000;
endmodule

`default_nettype wire
