// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// PS/2 set 2 scan codes to the machine's key matrix.
//
// The matrix is the same forty keys the Next uses, so this decode carries
// over; the Next's extra keys are additions to the table rather than a
// different scheme.
//
// Two prefixes matter. 0xf0 means the next code is a release, and 0xe0 marks
// the extended codes, which is where the cursor keys live. A few keys a modern
// keyboard has and a Spectrum does not are mapped to the combination the ROM
// expects: the cursor keys and backspace are caps shift with a digit. Those
// hold caps shift through a separate bit, so letting go of an arrow does not
// release a caps shift the typist is genuinely holding.

`default_nettype none

module nexttang_ps2_matrix (
    input  wire        clock,
    input  wire        reset,
    input  wire [7:0]  scancode,
    input  wire        scancode_valid,
    output wire [39:0] keys
);
    // {found, with caps shift, row, column}
    function [7:0] lookup(input is_extended, input [7:0] code);
        begin
            lookup = 8'h00;
            if (!is_extended) begin
                case (code)
                    8'h1a: lookup = {1'b1, 1'b0, 3'd0, 3'd1};  // Z
                    8'h22: lookup = {1'b1, 1'b0, 3'd0, 3'd2};  // X
                    8'h21: lookup = {1'b1, 1'b0, 3'd0, 3'd3};  // C
                    8'h2a: lookup = {1'b1, 1'b0, 3'd0, 3'd4};  // V
                    8'h1c: lookup = {1'b1, 1'b0, 3'd1, 3'd0};  // A
                    8'h1b: lookup = {1'b1, 1'b0, 3'd1, 3'd1};  // S
                    8'h23: lookup = {1'b1, 1'b0, 3'd1, 3'd2};  // D
                    8'h2b: lookup = {1'b1, 1'b0, 3'd1, 3'd3};  // F
                    8'h34: lookup = {1'b1, 1'b0, 3'd1, 3'd4};  // G
                    8'h15: lookup = {1'b1, 1'b0, 3'd2, 3'd0};  // Q
                    8'h1d: lookup = {1'b1, 1'b0, 3'd2, 3'd1};  // W
                    8'h24: lookup = {1'b1, 1'b0, 3'd2, 3'd2};  // E
                    8'h2d: lookup = {1'b1, 1'b0, 3'd2, 3'd3};  // R
                    8'h2c: lookup = {1'b1, 1'b0, 3'd2, 3'd4};  // T
                    8'h16: lookup = {1'b1, 1'b0, 3'd3, 3'd0};  // 1
                    8'h1e: lookup = {1'b1, 1'b0, 3'd3, 3'd1};  // 2
                    8'h26: lookup = {1'b1, 1'b0, 3'd3, 3'd2};  // 3
                    8'h25: lookup = {1'b1, 1'b0, 3'd3, 3'd3};  // 4
                    8'h2e: lookup = {1'b1, 1'b0, 3'd3, 3'd4};  // 5
                    8'h45: lookup = {1'b1, 1'b0, 3'd4, 3'd0};  // 0
                    8'h46: lookup = {1'b1, 1'b0, 3'd4, 3'd1};  // 9
                    8'h3e: lookup = {1'b1, 1'b0, 3'd4, 3'd2};  // 8
                    8'h3d: lookup = {1'b1, 1'b0, 3'd4, 3'd3};  // 7
                    8'h36: lookup = {1'b1, 1'b0, 3'd4, 3'd4};  // 6
                    8'h4d: lookup = {1'b1, 1'b0, 3'd5, 3'd0};  // P
                    8'h44: lookup = {1'b1, 1'b0, 3'd5, 3'd1};  // O
                    8'h43: lookup = {1'b1, 1'b0, 3'd5, 3'd2};  // I
                    8'h3c: lookup = {1'b1, 1'b0, 3'd5, 3'd3};  // U
                    8'h35: lookup = {1'b1, 1'b0, 3'd5, 3'd4};  // Y
                    8'h5a: lookup = {1'b1, 1'b0, 3'd6, 3'd0};  // ENTER
                    8'h4b: lookup = {1'b1, 1'b0, 3'd6, 3'd1};  // L
                    8'h42: lookup = {1'b1, 1'b0, 3'd6, 3'd2};  // K
                    8'h3b: lookup = {1'b1, 1'b0, 3'd6, 3'd3};  // J
                    8'h33: lookup = {1'b1, 1'b0, 3'd6, 3'd4};  // H
                    8'h29: lookup = {1'b1, 1'b0, 3'd7, 3'd0};  // SPACE
                    8'h3a: lookup = {1'b1, 1'b0, 3'd7, 3'd2};  // M
                    8'h31: lookup = {1'b1, 1'b0, 3'd7, 3'd3};  // N
                    8'h32: lookup = {1'b1, 1'b0, 3'd7, 3'd4};  // B
                    // Either shift is caps shift, either control is symbol
                    // shift, which is where a Spectrum keeps its punctuation.
                    8'h12: lookup = {1'b1, 1'b0, 3'd0, 3'd0};
                    8'h59: lookup = {1'b1, 1'b0, 3'd0, 3'd0};
                    8'h14: lookup = {1'b1, 1'b0, 3'd7, 3'd1};
                    8'h11: lookup = {1'b1, 1'b0, 3'd7, 3'd1};  // alt as well
                    8'h66: lookup = {1'b1, 1'b1, 3'd4, 3'd0};  // backspace
                    default: lookup = 8'h00;
                endcase
            end else begin
                case (code)
                    8'h6b: lookup = {1'b1, 1'b1, 3'd3, 3'd4};  // left, caps 5
                    8'h72: lookup = {1'b1, 1'b1, 3'd4, 3'd4};  // down, caps 6
                    8'h75: lookup = {1'b1, 1'b1, 3'd4, 3'd3};  // up, caps 7
                    8'h74: lookup = {1'b1, 1'b1, 3'd4, 3'd2};  // right, caps 8
                    8'h14: lookup = {1'b1, 1'b0, 3'd7, 3'd1};  // right control
                    8'h11: lookup = {1'b1, 1'b0, 3'd7, 3'd1};  // right alt
                    8'h5a: lookup = {1'b1, 1'b0, 3'd6, 3'd0};  // keypad enter
                    default: lookup = 8'h00;
                endcase
            end
        end
    endfunction

    reg [39:0] pressed;
    reg [4:0] combination_held;
    reg extended;
    reg releasing;

    // Decoded where it is used. A function call in a continuous assignment or
    // an implicit sensitivity list does not reliably re-evaluate when only the
    // prefix register changes, which silently broke every release and every
    // extended key.
    reg [7:0] decoded;
    wire found = decoded[7];
    wire with_caps = decoded[6];
    wire [5:0] index = {3'b0, decoded[5:3]} * 6'd5 + {3'b0, decoded[2:0]};

    // Caps shift is held while any key that needs it is down, on top of a
    // physically held shift.
    assign keys = pressed | {39'b0, |combination_held};

    always @(posedge clock) begin
        if (reset) begin
            pressed <= 0;
            combination_held <= 0;
            extended <= 1'b0;
            releasing <= 1'b0;
        end else if (scancode_valid) begin
            if (scancode == 8'he0) begin
                extended <= 1'b1;
            end else if (scancode == 8'hf0) begin
                releasing <= 1'b1;
            end else begin
                decoded = lookup(extended, scancode);
                extended <= 1'b0;
                releasing <= 1'b0;
                if (decoded[7]) begin
                    pressed[{3'b0, decoded[5:3]} * 6'd5 + {3'b0, decoded[2:0]}] <= !releasing;
                    if (decoded[6]) begin
                        // One bit per combination key so two at once behave.
                        case ({extended, scancode})
                            {1'b1, 8'h6b}: combination_held[0] <= !releasing;
                            {1'b1, 8'h72}: combination_held[1] <= !releasing;
                            {1'b1, 8'h75}: combination_held[2] <= !releasing;
                            {1'b1, 8'h74}: combination_held[3] <= !releasing;
                            default:       combination_held[4] <= !releasing;
                        endcase
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
