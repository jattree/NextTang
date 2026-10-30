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
//   H               colour mode off
//
// Hex digits are 0-9 and a-f or A-F. While raw bytes are arriving, payload
// is high and the board's other command decoders must ignore the bytes.

`default_nettype none

module nexttang_spec256_uart_loader (
    input  wire        clock,
    input  wire        reset,
    input  wire [7:0]  byte_in,
    input  wire        byte_valid,

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
    output reg  [7:0]  rules_flags
);
    localparam [2:0] IDLE = 3'd0;
    localparam [2:0] MODE = 3'd1;
    localparam [2:0] HEX = 3'd2;
    localparam [2:0] PLANES = 3'd3;
    localparam [2:0] PALETTE = 3'd4;

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

    assign payload = state == PLANES || state == PALETTE;

    always @(posedge clock) begin
        plane_write <= 1'b0;
        palette_write <= 1'b0;
        arm <= 1'b0;
        disarm <= 1'b0;
        if (reset) begin
            state <= IDLE;
            spec256_mode <= 1'b0;
            arm_pc <= 16'd0;
            rules_flags <= 8'd0;
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
                        "Q": begin palette_bytes <= 10'd0; state <= PALETTE; end
                        "H": disarm <= 1'b1;
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

                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
