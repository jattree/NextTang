// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Which of a Spec256 game's backgrounds to show: the .256's BGX1 rules, as
// Alberto Conde's SPEC256_MISTER applies them, or its BGX2 rules, which a
// player that knows them uses instead.
//
// The loader sends four header bytes (count, rule count, default, reserved)
// and the 64-byte rules, as load_index 0 up: BGX1 always has eight rules, 516
// bytes in all; BGX2 (load_wide) has as many as its rule count, up to 64, and
// byte 0 is E, the number of extra backgrounds. load_last marks the last byte.
// Rule byte 0 is the background it picks; bytes 2 to 17 and 18 to 33 are its
// two conditions, each
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
// What a rule or the default picks: BGX1 has 0 to 3, 4 for none and anything
// else keeps the current one. BGX2 has 0 to 3+E, 0xFE for none, and anything
// else keeps it. BGX1's values are put in BGX2's terms as they load.
//
// Each frame the rules are walked in order, a condition every four cycles, at
// most 512 cycles, and the background becomes the first rule's whose two
// conditions hold, or the default if none does. selected is that background,
// or NONE. Without rules (clear, until a load ends) or while the game is not
// running, background 0 is shown and nothing is watched: a load's own writes
// are not the game's.
//
// A write must reach every watcher in its cycle: writes can be 5 clocks apart
// with the CPU at 28 MHz, too close to look one up a condition at a time. 128
// comparators in parallel filled the chip's routing (the build never finished),
// so conditions share up to SLOTS watched values, one for each different
// address, width and starting value, and everything else is RAM. Rules usually
// watch few addresses: That Sinking Feeling's eight watch one. A condition past
// the last slot can never hold, and sets overflow; the loaders check first and
// play such a file from BGX1 instead.

`default_nettype none

module nexttang_spec256_background_rules (
    input  wire        clock,
    input  wire        reset,

    input  wire        clear,         // rules gone (the loader's H)
    input  wire        load_write,
    input  wire        load_wide,     // the rules being loaded are BGX2's
    input  wire        load_last,
    input  wire [12:0] load_index,
    input  wire [7:0]  load_data,

    input  wire        running,
    input  wire        frame,

    // The game's RAM writes: bank * 0x4000 + offset.
    input  wire        write,
    input  wire [16:0] write_address,
    input  wire [7:0]  write_data,

    output reg         valid,
    output reg  [5:0]  selected,      // 0 to 31, or NONE
    output reg         overflow       // more watched values than slots
);
    parameter integer SLOTS = 16;

    localparam [5:0] NONE = 6'd32;
    localparam [7:0] PICK_NONE = 8'hfe;
    localparam [7:0] PICK_KEEP = 8'hff;

    reg [6:0]  rule_count;
    reg [7:0]  default_background;
    reg [5:0]  image_limit;           // pictures numbered below this exist

    // Every slot is compared with every write, so these stay registers: left to
    // itself, synthesis makes them RAM and copies it for each read.
    (* syn_ramstyle = "registers" *) reg [16:0] slot_address [0:SLOTS-1];
    (* syn_ramstyle = "registers" *) reg [2:0]  slot_width [0:SLOTS-1];
    (* syn_ramstyle = "registers" *) reg [31:0] slot_value [0:SLOTS-1];
    reg [4:0]  slots_used;
    // test, slot, value to compare with, mask
    (* syn_ramstyle = "block_ram" *) reg [71:0] condition_ram [0:127];
    reg [7:0]  action_ram [0:63];

    // Load byte decoding: rule (index - 4) / 64, field (index - 4) % 64; a
    // condition's field (field - 2) % 16, condition (field - 2) / 16.
    wire [12:0] rule_offset = load_index - 13'd4;
    wire [5:0] load_rule = rule_offset[11:6];
    wire [5:0] load_field = rule_offset[5:0];
    wire [5:0] condition_offset = load_field - 6'd2;
    wire [6:0] load_condition = {load_rule, condition_offset[4]};
    wire [3:0] condition_field = condition_offset[3:0];
    wire in_rules = load_index >= 13'd4;
    wire in_condition = load_field >= 6'd2 && load_field < 6'd34;

    function [7:0] pick;
        input       wide;
        input [7:0] value;
        begin
            if (wide)
                pick = value;
            else if (value < 8'd4)
                pick = value;
            else if (value == 8'd4)
                pick = PICK_NONE;
            else
                pick = PICK_KEEP;
        end
    endfunction

    // A condition's bytes gather here until it is whole, at its last byte.
    reg [63:0] gathered;
    reg [16:0] load_address;
    reg [2:0]  load_width;
    reg [3:0]  load_test;
    reg [31:0] load_start;

    wire action_write = load_write && in_rules && load_field == 6'd0;
    wire condition_done = load_write && in_rules && in_condition &&
                          condition_field == 4'd15;
    wire [31:0] finished_start = {load_data, load_start[31:8]};

    // Is this condition's watched value already in a slot?
    reg        match_found;
    reg [3:0]  match_slot;
    integer m;
    always @* begin
        match_found = 1'b0;
        match_slot = 4'd0;
        for (m = SLOTS - 1; m >= 0; m = m - 1)
            if (m < slots_used && slot_address[m] == load_address &&
                slot_width[m] == load_width && slot_value[m] == finished_start) begin
                match_found = 1'b1;
                match_slot = m[3:0];
            end
    end
    wire no_watch = load_test == 4'd0;
    wire slots_full = slots_used == SLOTS;
    wire new_slot = condition_done && !no_watch && !match_found && !slots_full;
    wire no_room = condition_done && !no_watch && !match_found && slots_full;
    wire [3:0] condition_slot = match_found ? match_slot : slots_used[3:0];
    wire [3:0] stored_test = no_room ? 4'hf : load_test;   // never true

    // Writes are taken a cycle late, then compared.
    reg        write_d;
    reg [16:0] write_address_d;
    reg [7:0]  write_data_d;
    reg [16:0] offset;

    integer c;
    always @(posedge clock) begin
        write_d <= write && running && valid;
        write_address_d <= write_address;
        write_data_d <= write_data;

        if (load_write && in_rules && in_condition) begin
            if (condition_field == 4'd0)
                load_address[7:0] <= load_data;
            if (condition_field == 4'd1)
                load_address[15:8] <= load_data;
            if (condition_field == 4'd2)
                load_address[16] <= load_data[0];
            if (condition_field == 4'd3) begin
                load_test <= load_data[7:4];
                load_width <= load_data[3:0] > 4'd4 ? 3'd4 : load_data[2:0];
            end
            if (condition_field >= 4'd4 && condition_field <= 4'd11)
                gathered <= {load_data, gathered[63:8]};
            if (condition_field >= 4'd12)
                load_start <= finished_start;
        end

        if (new_slot) begin
            slot_address[slots_used[3:0]] <= load_address;
            slot_width[slots_used[3:0]] <= load_width;
            slot_value[slots_used[3:0]] <= finished_start;
        end else if (write_d) begin
            for (c = 0; c < SLOTS; c = c + 1) begin
                offset = write_address_d - slot_address[c];
                if (offset[16:2] == 15'd0 && {1'b0, offset[1:0]} < slot_width[c])
                    slot_value[c][8*offset[1:0] +: 8] <= write_data_d;
            end
        end

        if (reset || clear) begin
            valid <= 1'b0;
            rule_count <= 7'd0;
            default_background <= 8'd0;
            image_limit <= 6'd4;
            slots_used <= 5'd0;
            overflow <= 1'b0;
        end else if (load_write) begin
            if (load_index == 13'd0) begin
                valid <= 1'b0;
                slots_used <= 5'd0;
                overflow <= 1'b0;
                image_limit <= !load_wide ? 6'd4 :
                               load_data > 8'd28 ? 6'd32 : load_data[5:0] + 6'd4;
            end
            if (load_index == 13'd1) begin
                if (load_wide)
                    rule_count <= load_data > 8'd64 ? 7'd64 : load_data[6:0];
                else
                    rule_count <= load_data > 8'd8 ? 7'd8 : load_data[6:0];
            end
            if (load_index == 13'd2)
                default_background <= pick(load_wide, load_data);
            if (new_slot)
                slots_used <= slots_used + 5'd1;
            if (no_room)
                overflow <= 1'b1;
            if (load_last)
                valid <= 1'b1;
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

    // The walk: read a condition, then its slot, test it, take the result; after
    // each second condition the rule is decided, and after the last the action
    // is read.
    localparam [2:0] IDLE = 3'd0;
    localparam [2:0] READ = 3'd1;
    localparam [2:0] TEST = 3'd2;
    localparam [2:0] DECIDE = 3'd3;
    localparam [2:0] ACTION = 3'd4;
    localparam [2:0] APPLY = 3'd5;
    localparam [2:0] SLOT = 3'd6;

    reg [2:0]  state;
    reg [7:0]  walk;                  // the condition being tested
    reg [71:0] condition_read;
    reg [31:0] watched_read;
    reg        condition_holds;
    reg        first_holds;
    reg        found;
    reg [5:0]  winner;
    reg [7:0]  action_read;

    wire [7:0] walk_end = {rule_count, 1'b0};
    wire [7:0] picked = found ? action_read : default_background;

    always @(posedge clock) begin
        if (action_write)
            action_ram[load_rule] <= pick(load_wide, load_data);
        action_read <= action_ram[winner];
        if (condition_done)
            condition_ram[load_condition] <= {stored_test, condition_slot, gathered};
        condition_read <= condition_ram[walk[6:0]];
        watched_read <= slot_value[condition_read[67:64]];

        if (reset || clear || !valid || !running) begin
            selected <= 6'd0;
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    walk <= 8'd0;
                    found <= 1'b0;
                    if (frame)
                        state <= rule_count == 7'd0 ? ACTION : READ;
                end

                READ:
                    state <= SLOT;

                SLOT:
                    state <= TEST;

                TEST: begin
                    condition_holds <= holds(watched_read, condition_read[31:0],
                                             condition_read[63:32], condition_read[71:68]);
                    state <= DECIDE;
                end

                DECIDE: begin
                    if (!walk[0]) begin
                        first_holds <= condition_holds;
                    end else if (first_holds && condition_holds && !found) begin
                        found <= 1'b1;
                        winner <= walk[6:1];
                    end
                    walk <= walk + 8'd1;
                    state <= walk + 8'd1 == walk_end ? ACTION : READ;
                end

                ACTION:
                    state <= APPLY;

                APPLY: begin
                    if (picked == PICK_NONE)
                        selected <= NONE;
                    else if (picked < {2'b00, image_limit})
                        selected <= picked[5:0];
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
