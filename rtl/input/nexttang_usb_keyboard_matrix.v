// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Translate a USB boot-keyboard report into the forty-key Spectrum matrix.
// The HID host retains the four currently pressed usage codes, so this path is
// combinational and releases a key as soon as it disappears from the report.

`default_nettype none

module nexttang_usb_keyboard_matrix (
    input  wire [1:0] device_type,
    input  wire [7:0] modifiers,
    input  wire [7:0] key1,
    input  wire [7:0] key2,
    input  wire [7:0] key3,
    input  wire [7:0] key4,
    input  wire [7:0] key5,
    input  wire [7:0] key6,
    output wire [39:0] keys
);
    localparam [1:0] TYPE_KEYBOARD = 2'd1;

    function automatic [39:0] decode_key(input [7:0] code);
        begin
            decode_key = 40'b0;
            case (code)
                // A-Z, HID usages 04-1d.
                8'h04: decode_key[5]  = 1'b1;  // A
                8'h05: decode_key[39] = 1'b1;  // B
                8'h06: decode_key[3]  = 1'b1;  // C
                8'h07: decode_key[7]  = 1'b1;  // D
                8'h08: decode_key[12] = 1'b1;  // E
                8'h09: decode_key[8]  = 1'b1;  // F
                8'h0a: decode_key[9]  = 1'b1;  // G
                8'h0b: decode_key[34] = 1'b1;  // H
                8'h0c: decode_key[27] = 1'b1;  // I
                8'h0d: decode_key[33] = 1'b1;  // J
                8'h0e: decode_key[32] = 1'b1;  // K
                8'h0f: decode_key[31] = 1'b1;  // L
                8'h10: decode_key[37] = 1'b1;  // M
                8'h11: decode_key[38] = 1'b1;  // N
                8'h12: decode_key[26] = 1'b1;  // O
                8'h13: decode_key[25] = 1'b1;  // P
                8'h14: decode_key[10] = 1'b1;  // Q
                8'h15: decode_key[13] = 1'b1;  // R
                8'h16: decode_key[6]  = 1'b1;  // S
                8'h17: decode_key[14] = 1'b1;  // T
                8'h18: decode_key[28] = 1'b1;  // U
                8'h19: decode_key[4]  = 1'b1;  // V
                8'h1a: decode_key[11] = 1'b1;  // W
                8'h1b: decode_key[2]  = 1'b1;  // X
                8'h1c: decode_key[29] = 1'b1;  // Y
                8'h1d: decode_key[1]  = 1'b1;  // Z

                // Number row.
                8'h1e: decode_key[15] = 1'b1;  // 1
                8'h1f: decode_key[16] = 1'b1;  // 2
                8'h20: decode_key[17] = 1'b1;  // 3
                8'h21: decode_key[18] = 1'b1;  // 4
                8'h22: decode_key[19] = 1'b1;  // 5
                8'h23: decode_key[24] = 1'b1;  // 6
                8'h24: decode_key[23] = 1'b1;  // 7
                8'h25: decode_key[22] = 1'b1;  // 8
                8'h26: decode_key[21] = 1'b1;  // 9
                8'h27: decode_key[20] = 1'b1;  // 0

                8'h28: decode_key[30] = 1'b1;  // ENTER
                8'h2c: decode_key[35] = 1'b1;  // SPACE

                // DELETE and cursor keys are Spectrum shifted combinations.
                8'h2a: begin decode_key[0] = 1'b1; decode_key[20] = 1'b1; end
                8'h4f: begin decode_key[0] = 1'b1; decode_key[22] = 1'b1; end
                8'h50: begin decode_key[0] = 1'b1; decode_key[19] = 1'b1; end
                8'h51: begin decode_key[0] = 1'b1; decode_key[24] = 1'b1; end
                8'h52: begin decode_key[0] = 1'b1; decode_key[23] = 1'b1; end
                default: decode_key = 40'b0;
            endcase
        end
    endfunction

    wire [39:0] pressed = decode_key(key1) | decode_key(key2) |
                          decode_key(key3) | decode_key(key4) |
                          decode_key(key5) | decode_key(key6);
    wire caps_shift = modifiers[1] | modifiers[5];
    wire symbol_shift = modifiers[0] | modifiers[2] |
                        modifiers[4] | modifiers[6];
    wire [39:0] modifier_keys =
        ({40{caps_shift}} & (40'b1 << 0)) |
        ({40{symbol_shift}} & (40'b1 << 36));

    assign keys = device_type == TYPE_KEYBOARD
        ? pressed | modifier_keys : 40'b0;
endmodule

`default_nettype wire
