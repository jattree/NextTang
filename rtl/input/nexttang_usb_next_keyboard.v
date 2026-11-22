// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A USB keyboard as the ZX Spectrum Next's own PS/2 keyboard.
//
// The Next turns PS/2 scan codes into its 8x7 keyboard matrix (the Spectrum's
// forty keys plus two columns of extra keys: EXTEND, UP, CAPS LOCK, GRAPH,
// TRUE and INV VIDEO, BREAK, EDIT, ; " , . DELETE and the cursor keys) through
// a keymap that software can rewrite with NextREGs 0x28-0x2B; NextZXOS and
// its keymap files choose the layout that way. This module does the same for
// a USB keyboard's key events: each usage is translated to its PS/2 set 2
// scan code (with the E0 prefix as bit 8), looked up in the official keymap
// (rtl/input/keymaps.vhd, US by default, written from the core), and the
// result kept in a matrix exactly as the official ps2_keyb.vhd keeps it,
// including its count of keys that add CAPS or SYMBOL SHIFT. The official
// membrane (rtl/input/membrane.vhd) scans the matrix a row at a time, as it
// scans a real Next's keyboard.
//
// Events: event_valid with event_byte = usage (bits 6-0, as the BL616's
// FPGA-Companion sends it: 0x68 + n for the boot report's modifier bit n)
// and bit 7 set on release. Usages with no PS/2 code are ignored. Keymap
// entries for function keys (bits 7-6 both set) are left to the caller,
// which already takes F1-F10 from the USB keys.

`default_nettype none

module nexttang_usb_next_keyboard (
    input  wire       clock,
    input  wire       reset,

    input  wire       event_valid,
    input  wire [7:0] event_byte,

    // the core's keymap writes (o_KEYMAP_*)
    input  wire [8:0] keymap_address,
    input  wire [7:0] keymap_data,
    input  wire       keymap_write,

    // the membrane's row index and the matrix's seven columns there, 0 = down
    input  wire [2:0] membrane_row,
    output wire [6:0] membrane_columns
);
    // USB HID usage (or 0x68 + modifier bit) to PS/2 set 2: {E0, code};
    // 9'h000 = none.
    function automatic [8:0] set2(input [6:0] usage);
        begin
            case (usage)
                7'h04: set2 = 9'h01C; 7'h05: set2 = 9'h032; 7'h06: set2 = 9'h021; 7'h07: set2 = 9'h023;  // A B C D
                7'h08: set2 = 9'h024; 7'h09: set2 = 9'h02B; 7'h0A: set2 = 9'h034; 7'h0B: set2 = 9'h033;  // E F G H
                7'h0C: set2 = 9'h043; 7'h0D: set2 = 9'h03B; 7'h0E: set2 = 9'h042; 7'h0F: set2 = 9'h04B;  // I J K L
                7'h10: set2 = 9'h03A; 7'h11: set2 = 9'h031; 7'h12: set2 = 9'h044; 7'h13: set2 = 9'h04D;  // M N O P
                7'h14: set2 = 9'h015; 7'h15: set2 = 9'h02D; 7'h16: set2 = 9'h01B; 7'h17: set2 = 9'h02C;  // Q R S T
                7'h18: set2 = 9'h03C; 7'h19: set2 = 9'h02A; 7'h1A: set2 = 9'h01D; 7'h1B: set2 = 9'h022;  // U V W X
                7'h1C: set2 = 9'h035; 7'h1D: set2 = 9'h01A;                                              // Y Z
                7'h1E: set2 = 9'h016; 7'h1F: set2 = 9'h01E; 7'h20: set2 = 9'h026; 7'h21: set2 = 9'h025;  // 1 2 3 4
                7'h22: set2 = 9'h02E; 7'h23: set2 = 9'h036; 7'h24: set2 = 9'h03D; 7'h25: set2 = 9'h03E;  // 5 6 7 8
                7'h26: set2 = 9'h046; 7'h27: set2 = 9'h045;                                              // 9 0
                7'h28: set2 = 9'h05A; 7'h29: set2 = 9'h076; 7'h2A: set2 = 9'h066; 7'h2B: set2 = 9'h00D;  // Enter Esc Backspace Tab
                7'h2C: set2 = 9'h029; 7'h2D: set2 = 9'h04E; 7'h2E: set2 = 9'h055; 7'h2F: set2 = 9'h054;  // Space - = [
                7'h30: set2 = 9'h05B; 7'h31: set2 = 9'h05D; 7'h32: set2 = 9'h05D; 7'h33: set2 = 9'h04C;  // ] \ (non-US #) ;
                7'h34: set2 = 9'h052; 7'h35: set2 = 9'h00E; 7'h36: set2 = 9'h041; 7'h37: set2 = 9'h049;  // ' ` , .
                7'h38: set2 = 9'h04A; 7'h39: set2 = 9'h058;                                              // / Caps Lock
                7'h3A: set2 = 9'h005; 7'h3B: set2 = 9'h006; 7'h3C: set2 = 9'h004; 7'h3D: set2 = 9'h00C;  // F1-F4
                7'h3E: set2 = 9'h003; 7'h3F: set2 = 9'h00B; 7'h40: set2 = 9'h083; 7'h41: set2 = 9'h00A;  // F5-F8
                7'h42: set2 = 9'h001; 7'h43: set2 = 9'h009; 7'h44: set2 = 9'h078; 7'h45: set2 = 9'h007;  // F9-F12
                7'h47: set2 = 9'h07E;                                                                    // Scroll Lock
                7'h49: set2 = 9'h170; 7'h4A: set2 = 9'h16C; 7'h4B: set2 = 9'h17D; 7'h4C: set2 = 9'h171;  // Ins Home PgUp Del
                7'h4D: set2 = 9'h169; 7'h4E: set2 = 9'h17A; 7'h4F: set2 = 9'h174; 7'h50: set2 = 9'h16B;  // End PgDn Right Left
                7'h51: set2 = 9'h172; 7'h52: set2 = 9'h175;                                              // Down Up
                7'h53: set2 = 9'h077; 7'h54: set2 = 9'h14A; 7'h55: set2 = 9'h07C; 7'h56: set2 = 9'h07B;  // Num Lock KP/ KP* KP-
                7'h57: set2 = 9'h079; 7'h58: set2 = 9'h15A; 7'h59: set2 = 9'h069; 7'h5A: set2 = 9'h072;  // KP+ KPEnter KP1 KP2
                7'h5B: set2 = 9'h07A; 7'h5C: set2 = 9'h06B; 7'h5D: set2 = 9'h073; 7'h5E: set2 = 9'h074;  // KP3-KP6
                7'h5F: set2 = 9'h06C; 7'h60: set2 = 9'h075; 7'h61: set2 = 9'h07D; 7'h62: set2 = 9'h070;  // KP7-KP9 KP0
                7'h63: set2 = 9'h071; 7'h64: set2 = 9'h061; 7'h65: set2 = 9'h12F;                        // KP. non-US \ Menu
                7'h68: set2 = 9'h014; 7'h69: set2 = 9'h012; 7'h6A: set2 = 9'h011; 7'h6B: set2 = 9'h11F;  // LCtrl LShift LAlt LGUI
                7'h6C: set2 = 9'h114; 7'h6D: set2 = 9'h059; 7'h6E: set2 = 9'h111; 7'h6F: set2 = 9'h127;  // RCtrl RShift RAlt RGUI
                default: set2 = 9'h000;
            endcase
        end
    endfunction

    // the event, registered, then the keymap's answer one clock later
    reg        pending = 1'b0;
    reg        release_q = 1'b0;
    reg  [8:0] code_q = 9'd0;
    wire [8:0] code = set2(event_byte[6:0]);
    always @(posedge clock) begin
        pending <= 1'b0;
        if (event_valid && code != 9'd0) begin
            pending <= 1'b1;
            release_q <= event_byte[7];
            code_q <= code;
        end
    end

    // The keymap is read on the falling edge, as ps2_keyb.vhd clocks it from
    // the inverted clock: the answer is there by the next rising edge.
    wire [8:0] keymap_out;
    keymaps keymap (
        .clock_i(~clock),
        .addr_wr_i(keymap_address), .data_i({1'b0, keymap_data}), .we_i(keymap_write),
        .addr_rd_i(code_q), .data_o(keymap_out)
    );

    // ps2_keyb.vhd's matrix: 1 = up; CAPS and SYMBOL SHIFT added by keymap
    // entries are counted, so they hold while any key that adds them is down
    reg  [6:0] matrix [0:7];
    reg  [2:0] caps_count = 3'd0, sym_count = 3'd0;
    integer    r;
    initial for (r = 0; r < 8; r = r + 1) matrix[r] = 7'h7F;
    wire       key_entry = keymap_out[7:6] != 2'b11;   // 11: a function key
    always @(posedge clock) begin
        if (reset) begin
            for (r = 0; r < 8; r = r + 1) matrix[r] <= 7'h7F;
            caps_count <= 3'd0;
            sym_count <= 3'd0;
        end else if (pending && key_entry) begin
            if (keymap_out[6]) begin
                if (!release_q) caps_count <= caps_count + 3'd1;
                else if (caps_count != 3'd0) caps_count <= caps_count - 3'd1;
            end
            if (keymap_out[7]) begin
                if (!release_q) sym_count <= sym_count + 3'd1;
                else if (sym_count != 3'd0) sym_count <= sym_count - 3'd1;
            end
            if (keymap_out[2:0] != 3'b111)
                matrix[keymap_out[5:3]][keymap_out[2:0]] <= release_q;
        end
    end

    wire [6:0] row_now = matrix[membrane_row];
    assign membrane_columns = {row_now[6:2],
                               row_now[1] & (membrane_row != 3'd7 || sym_count == 3'd0),
                               row_now[0] & (membrane_row != 3'd0 || caps_count == 3'd0)};
endmodule

`default_nettype wire
