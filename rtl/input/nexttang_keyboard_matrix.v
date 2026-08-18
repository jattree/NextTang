// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// The ZX Spectrum keyboard as the machine sees it.
//
// Reading port 0xFE returns five bits. Which keys those bits describe is chosen
// by the high half of the address: each of the eight address lines that is low
// selects one half-row, and a zero in the result means pressed. Software drives
// several lines low at once to scan a group in one read, so the result is the
// AND of every selected half-row rather than a lookup.
//
// The key vector is five bits per half-row in the order the hardware scans:
//
//   0  CAPS SHIFT  Z  X  C  V        4  0  9  8  7  6
//   1  A  S  D  F  G                 5  P  O  I  U  Y
//   2  Q  W  E  R  T                 6  ENTER  L  K  J  H
//   3  1  2  3  4  5                 7  SPACE  SYM SHIFT  M  N  B
//
// Nothing here knows where key presses come from, so the same module serves a
// real keyboard and a synthetic one.

`default_nettype none

module nexttang_keyboard_matrix (
    input  wire [7:0]  row_select,   // address[15:8], a low bit selects a row
    input  wire [39:0] keys,         // 1 means pressed
    output reg  [4:0]  columns       // 0 means pressed
);
    integer row;

    always @(*) begin
        columns = 5'b11111;
        for (row = 0; row < 8; row = row + 1)
            if (!row_select[row])
                columns = columns & ~keys[row * 5 +: 5];
    end
endmodule

`default_nettype wire
