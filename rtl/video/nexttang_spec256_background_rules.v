// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Which of a Spec256 game's backgrounds to show: the .256's BGX1 rules, as
// Alberto Conde's SPEC256_MISTER applies them.
//
// The loader sends BGX1's bytes 4 to 7 (count, rule count, default,
// reserved) and its eight 64-byte rules, 516 bytes in all, as load_index 0
// to 515. Rule byte 0 is the background it picks; bytes 2 to 17 and 18 to 33
// are its two conditions, each
//   0-2    the watched address, 17 bits little-endian: RAM bank * 0x4000 +
//          offset, as a 128K machine pages it
//   3      the test (high nibble: 0 none, 1 =, 2 !=, 3 <, 4 >=, others never
//          true) and the width in bytes (low nibble, 1 to 4)
//   4-7    mask, 8-11 the value to compare with, 12-15 the value before the
//          game starts, all 32 bits little-endian
// A condition watches its bytes as the game writes them, from the address
// up, the first in bits 7:0. Its test compares the watched value and the
// value to compare with, both masked, unsigned; a rule without a test
// counts as true. The rule count says how many rules there are.
//
// Once a frame (frame) the background becomes the first rule's whose two
// conditions hold, or the default if none does, unless that is 255 (keep
// the current one) or above 4; 4 shows none. Without rules (clear, until a
// load ends) or while the game is not running, background 0 is shown and
// nothing is watched: a load's own writes are not the game's.

`default_nettype none

module nexttang_spec256_background_rules (
    input  wire        clock,
    input  wire        reset,

    input  wire        clear,         // rules gone (the loader's H)
    input  wire        load_write,
    input  wire [9:0]  load_index,
    input  wire [7:0]  load_data,

    input  wire        running,
    input  wire        frame,

    // The game's RAM writes: bank * 0x4000 + offset.
    input  wire        write,
    input  wire [16:0] write_address,
    input  wire [7:0]  write_data,

    output reg         valid,
    output reg  [2:0]  selected
);
    reg [7:0]  rule_count;
    reg [7:0]  default_background;
    reg [7:0]  action [0:7];
    reg [16:0] watch_address [0:15];
    reg [7:0]  test [0:15];
    reg [31:0] mask [0:15];
    reg [31:0] wanted [0:15];
    reg [31:0] watched [0:15];

    // Load byte decoding: rule (index - 4) / 64, field (index - 4) % 64; a
    // condition's field (field - 2) % 16, condition (field - 2) / 16.
    wire [9:0] rule_offset = load_index - 10'd4;
    wire [2:0] load_rule = rule_offset[8:6];
    wire [5:0] load_field = rule_offset[5:0];
    wire [5:0] condition_offset = load_field - 6'd2;
    wire [3:0] load_condition = {load_rule, condition_offset[4]};
    wire [3:0] condition_field = condition_offset[3:0];
    wire in_rules = load_index >= 10'd4 && load_index < 10'd516;
    wire in_condition = load_field >= 6'd2 && load_field < 6'd34;

    // Writes are taken a cycle late, then compared.
    reg        write_d;
    reg [16:0] write_address_d;
    reg [7:0]  write_data_d;

    integer c, r;
    always @(posedge clock) begin
        write_d <= write && running && valid;
        write_address_d <= write_address;
        write_data_d <= write_data;

        if (reset || clear) begin
            valid <= 1'b0;
            rule_count <= 8'd0;
            default_background <= 8'd0;
        end else if (load_write) begin
            if (load_index == 10'd0)
                valid <= 1'b0;
            if (load_index == 10'd1)
                rule_count <= load_data;
            if (load_index == 10'd2)
                default_background <= load_data;
            if (load_index == 10'd515)
                valid <= 1'b1;
            if (in_rules && load_field == 6'd0)
                action[load_rule] <= load_data;
            if (in_rules && in_condition)
                case (condition_field)
                    4'd0: watch_address[load_condition][7:0] <= load_data;
                    4'd1: watch_address[load_condition][15:8] <= load_data;
                    4'd2: watch_address[load_condition][16] <= load_data[0];
                    4'd3: test[load_condition] <= load_data;
                    4'd4: mask[load_condition][7:0] <= load_data;
                    4'd5: mask[load_condition][15:8] <= load_data;
                    4'd6: mask[load_condition][23:16] <= load_data;
                    4'd7: mask[load_condition][31:24] <= load_data;
                    4'd8: wanted[load_condition][7:0] <= load_data;
                    4'd9: wanted[load_condition][15:8] <= load_data;
                    4'd10: wanted[load_condition][23:16] <= load_data;
                    4'd11: wanted[load_condition][31:24] <= load_data;
                    4'd12: watched[load_condition][7:0] <= load_data;
                    4'd13: watched[load_condition][15:8] <= load_data;
                    4'd14: watched[load_condition][23:16] <= load_data;
                    4'd15: watched[load_condition][31:24] <= load_data;
                endcase
        end else if (write_d) begin
            for (c = 0; c < 16; c = c + 1)
                if (c < 2 * rule_count && test[c][7:4] != 4'd0)
                    for (r = 0; r < 4; r = r + 1)
                        if (r < test[c][3:0] && write_address_d == watch_address[c] + r)
                            watched[c][8*r +: 8] <= write_data_d;
        end
    end

    function holds;
        input [31:0] value, condition_mask, compare;
        input [3:0]  kind;
        reg   [31:0] actual, expected;
        begin
            actual = value & condition_mask;
            expected = compare & condition_mask;
            case (kind)
                4'd0: holds = 1'b1;
                4'd1: holds = actual == expected;
                4'd2: holds = actual != expected;
                4'd3: holds = actual < expected;
                4'd4: holds = actual >= expected;
                default: holds = 1'b0;
            endcase
        end
    endfunction

    // Each condition's result, registered; then the first rule that holds.
    reg [15:0] condition_true;
    reg [7:0]  candidate;
    reg [7:0]  chosen;
    integer k;
    always @(posedge clock) begin
        for (k = 0; k < 16; k = k + 1)
            condition_true[k] <= holds(watched[k], mask[k], wanted[k], test[k][7:4]);
    end

    always @* begin
        chosen = default_background;
        for (k = 7; k >= 0; k = k - 1)
            if (k < rule_count && condition_true[2*k] && condition_true[2*k+1])
                chosen = action[k];
    end

    always @(posedge clock) begin
        candidate <= chosen;
        if (reset || clear || !valid || !running)
            selected <= 3'd0;
        else if (frame && candidate != 8'hff && candidate < 8'd5)
            selected <= candidate[2:0];
    end
endmodule

`default_nettype wire
