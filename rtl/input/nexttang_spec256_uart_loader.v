// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Spec256 commands on the debug UART, for loading a game's colour data from
// the host until the Next can load it itself.
//
//   S0, S1          planes off/on: the Layer 2 mirror becomes the colour
//                   planes (spec256_mode)
//   Waaaannnn       then nnnn x 8 raw bytes: plane words from Spectrum
//                   address aaaa up, lane 0's byte first
//   Q               then 512 raw bytes: the palette, 256 RGB333 entries,
//                   low byte first
//   Gpppp           arm: colour mode from the next instruction fetched at
//                   pppp (the game's start, where every lane is still the
//                   master's copy)
//   Uff             the game's rules flags, byte 5 of the .256's RUL1 block
//                   (bit 0: Spec256 DOS render)
//   B               then 49152 raw bytes: the 256 x 192 background, one
//                   palette index per pixel, row by row (0: none); shown
//                   once the last byte has arrived
//   Mn              then 49152 raw bytes: background n (0 to 3; 1 to 3 are
//                   BGX1's B01 to B03) likewise; M0 is B
//   E               then 516 raw bytes: BGX1's bytes 4 to 7 (count, rule
//                   count, default, reserved) and its eight 64-byte rules,
//                   which pick the background shown
//   Pn              W's words for 0xC000 to 0xFFFF are bank n's (0 to 7;
//                   0 after H): the board keeps banks other than 5, 2 and
//                   0 in DDR3; banks_with_planes marks each n given (H
//                   clears it)
//   Cuuddff         the game's .CFG colours: UpColorsMixed, DownColorsMixed
//                   and flags (bit 3 BkOverFF, bit 7 CFG present)
//   Y               then 64 raw bytes: RUL1's eight rules (bytes 8 to 71 of
//                   the block), cleared by H
//   Zn              the ZX-Poly video mode, RUL1 byte 7 (0: none), cleared
//                   by H
//   Onn             the game's options, byte 8 of the .256's OPT1 block (bit 0:
//                   FLASH cells show the Spectrum's pixel in the on phase),
//                   cleared by H; senders give it only when non-zero, and an
//                   older core ignores the letter and its lower-case digits
//   Xnn             the paper's horizontal trim, a signed pixel count added
//                   to the left edge the board measures (kept by H)
//   H               everything off: colour mode, the planes (S0), rules
//                   flags, CFG, rules, ZX-Poly mode, options, backgrounds and
//                   BGX1 rules
//
// abort returns the parser to waiting for a command from any state, the
// middle of a raw payload included, without changing what was loaded.
//
// Hex digits are 0-9 and a-f or A-F. While raw bytes are arriving, payload
// is high and the board's other command decoders must ignore the bytes.

`default_nettype none

module nexttang_spec256_uart_loader (
    input  wire        clock,
    input  wire        reset,
    input  wire [7:0]  byte_in,
    input  wire        byte_valid,
    input  wire        abort,

    output wire        payload,
    output reg         spec256_mode,

    output reg         plane_write,
    output reg  [15:0] plane_address,
    output reg  [63:0] plane_data,

    output reg         palette_write,
    output reg  [7:0]  palette_index,
    output reg  [8:0]  palette_rgb,

    output reg         arm,          // one cycle: arm at arm_pc
    output reg  [15:0] arm_pc,
    output reg         disarm,       // one cycle
    output reg  [7:0]  rules_flags,

    output reg         background_write,
    output reg  [1:0]  background_image,
    output reg  [15:0] background_address,
    output reg  [7:0]  background_index,
    output wire        background_present,   // set by B, cleared by H
    output reg  [3:0]  backgrounds_present,  // image n complete, cleared by H
    output reg         bgx_clear,            // one cycle: H
    output reg         bgx_write,
    output reg  [9:0]  bgx_index,
    output reg  [7:0]  bgx_data,
    output reg  [23:0] cfg,                  // up, down, flags
    output reg  [511:0] rules,               // rule i in 64i+63..64i, byte j at 8j
    output reg  [2:0]  zxpoly_mode,
    output reg  [7:0]  options,              // OPT1 byte 8, cleared by H
    output reg  [7:0]  paper_trim,
    output reg  [2:0]  plane_bank,
    output reg  [7:0]  banks_with_planes
);
    localparam [2:0] IDLE = 3'd0;
    localparam [2:0] MODE = 3'd1;
    localparam [2:0] HEX = 3'd2;
    localparam [2:0] PLANES = 3'd3;
    localparam [2:0] PALETTE = 3'd4;
    localparam [2:0] BACKGROUND = 3'd5;
    localparam [2:0] RULES = 3'd6;
    localparam [2:0] BGX = 3'd7;

    reg [2:0]  state;
    reg [7:0]  command;
    reg [3:0]  digits_left;
    reg [31:0] value;
    reg [15:0] words_left;
    reg [15:0] next_address;
    reg [2:0]  byte_of_word;
    reg [9:0]  palette_bytes;
    reg [7:0]  low_byte;

    wire is_digit = (byte_in >= "0" && byte_in <= "9") ||
                    (byte_in >= "a" && byte_in <= "f") ||
                    (byte_in >= "A" && byte_in <= "F");
    wire [3:0] digit = byte_in <= "9" ? byte_in[3:0] : byte_in[3:0] + 4'd9;

    assign payload = state == PLANES || state == PALETTE || state == BACKGROUND ||
                     state == RULES || state == BGX;
    assign background_present = backgrounds_present[0];

    always @(posedge clock) begin
        plane_write <= 1'b0;
        palette_write <= 1'b0;
        arm <= 1'b0;
        disarm <= 1'b0;
        background_write <= 1'b0;
        bgx_clear <= 1'b0;
        bgx_write <= 1'b0;
        if (reset) begin
            state <= IDLE;
            spec256_mode <= 1'b0;
            arm_pc <= 16'd0;
            rules_flags <= 8'd0;
            backgrounds_present <= 4'd0;
            bgx_clear <= 1'b1;
            cfg <= 24'd0;
            rules <= 512'd0;
            zxpoly_mode <= 3'd0;
            options <= 8'd0;
            paper_trim <= 8'd0;
            plane_bank <= 3'd0;
            banks_with_planes <= 8'd0;
        end else if (abort) begin
            state <= IDLE;
        end else if (byte_valid) begin
            case (state)
                IDLE: begin
                    command <= byte_in;
                    value <= 32'd0;
                    case (byte_in)
                        "S": state <= MODE;
                        "W": begin digits_left <= 4'd8; state <= HEX; end
                        "G": begin digits_left <= 4'd4; state <= HEX; end
                        "U": begin digits_left <= 4'd2; state <= HEX; end
                        "C": begin digits_left <= 4'd6; state <= HEX; end
                        "B": begin
                            next_address <= 16'd0; background_image <= 2'd0;
                            backgrounds_present[0] <= 1'b0; state <= BACKGROUND;
                        end
                        "M": begin digits_left <= 4'd1; state <= HEX; end
                        "P": begin digits_left <= 4'd1; state <= HEX; end
                        "E": begin next_address <= 16'd0; state <= BGX; end
                        "Q": begin palette_bytes <= 10'd0; state <= PALETTE; end
                        "H": begin
                            disarm <= 1'b1; spec256_mode <= 1'b0; backgrounds_present <= 4'd0;
                            bgx_clear <= 1'b1;
                            rules_flags <= 8'd0; cfg <= 24'd0; rules <= 512'd0;
                            zxpoly_mode <= 3'd0; options <= 8'd0;
                            plane_bank <= 3'd0; banks_with_planes <= 8'd0;
                        end
                        "Z": begin digits_left <= 4'd1; state <= HEX; end
                        "X": begin digits_left <= 4'd2; state <= HEX; end
                        "O": begin digits_left <= 4'd2; state <= HEX; end
                        "Y": begin next_address <= 16'd0; state <= RULES; end
                        default: ;
                    endcase
                end

                MODE: begin
                    if (byte_in == "0" || byte_in == "1")
                        spec256_mode <= byte_in[0];
                    state <= IDLE;
                end

                HEX: begin
                    if (!is_digit) begin
                        state <= IDLE;
                    end else begin
                        value <= {value[27:0], digit};
                        digits_left <= digits_left - 4'd1;
                        if (digits_left == 4'd1) begin
                            if (command == "G") begin
                                arm_pc <= {value[11:0], digit};
                                arm <= 1'b1;
                                state <= IDLE;
                            end else if (command == "U") begin
                                rules_flags <= {value[3:0], digit};
                                state <= IDLE;
                            end else if (command == "Z") begin
                                zxpoly_mode <= digit[2:0];
                                state <= IDLE;
                            end else if (command == "X") begin
                                paper_trim <= {value[3:0], digit};
                                state <= IDLE;
                            end else if (command == "O") begin
                                options <= {value[3:0], digit};
                                state <= IDLE;
                            end else if (command == "P") begin
                                plane_bank <= digit[2:0];
                                banks_with_planes[digit[2:0]] <= 1'b1;
                                state <= IDLE;
                            end else if (command == "M") begin
                                next_address <= 16'd0;
                                background_image <= digit[1:0];
                                backgrounds_present[digit[1:0]] <= 1'b0;
                                state <= BACKGROUND;
                            end else if (command == "C") begin
                                cfg <= {value[19:0], digit};
                                state <= IDLE;
                            end else begin
                                next_address <= value[27:12];
                                words_left <= {value[11:0], digit};
                                byte_of_word <= 3'd0;
                                state <= {value[11:0], digit} == 16'd0 ? IDLE : PLANES;
                            end
                        end
                    end
                end

                PLANES: begin
                    plane_data <= {byte_in, plane_data[63:8]};
                    byte_of_word <= byte_of_word + 3'd1;
                    if (byte_of_word == 3'd7) begin
                        plane_write <= 1'b1;
                        plane_address <= next_address;
                        next_address <= next_address + 16'd1;
                        words_left <= words_left - 16'd1;
                        if (words_left == 16'd1)
                            state <= IDLE;
                    end
                end

                PALETTE: begin
                    palette_bytes <= palette_bytes + 10'd1;
                    if (!palette_bytes[0]) begin
                        low_byte <= byte_in;
                    end else begin
                        palette_write <= 1'b1;
                        palette_index <= palette_bytes[8:1];
                        palette_rgb <= {byte_in[0], low_byte};
                        if (palette_bytes == 10'd511)
                            state <= IDLE;
                    end
                end

                BACKGROUND: begin
                    background_write <= 1'b1;
                    background_address <= next_address;
                    background_index <= byte_in;
                    next_address <= next_address + 16'd1;
                    if (next_address == 16'd49151) begin
                        backgrounds_present[background_image] <= 1'b1;
                        state <= IDLE;
                    end
                end

                RULES: begin
                    rules <= {byte_in, rules[511:8]};
                    next_address <= next_address + 16'd1;
                    if (next_address == 16'd63)
                        state <= IDLE;
                end

                BGX: begin
                    bgx_write <= 1'b1;
                    bgx_index <= next_address[9:0];
                    bgx_data <= byte_in;
                    next_address <= next_address + 16'd1;
                    if (next_address == 16'd515)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
