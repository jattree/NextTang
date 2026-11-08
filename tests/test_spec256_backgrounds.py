"""Spec256's BGX1 and BGX2 backgrounds: the loader's E, L, M, A and P commands, the rules, and the DDR3 store.

The loader passes E's 516 bytes on in order as BGX1 bytes, L's 4 + 64 x rule
count as BGX2 bytes, and M's or A's 49152 as background n, marking it present
once complete; H drops every background and the rules (bgx_clear). P selects the bank W's 0xC000 words go to and marks
it as having planes; H returns to bank 0 and clears the marks.

nexttang_spec256_background_rules must pick backgrounds as SPEC256_MISTER
does: the first rule whose two conditions hold, else the default; only once a
frame; 255 or anything above 4 keeps the current one; a condition watches the
game's writes to its bytes (a two-byte condition takes its second byte from
the next address) and starts from the value the file gives; background 0
while not running or without rules, and writes made while not running are not
watched.

With BGX2 the same rules go up to 64, in order, sharing up to 16 watched values
that all see every write however close together; one past that can never hold
and sets overflow; 0 to 3+E pick a background, 0xFE none, and anything else keeps
the current one.

nexttang_spec256_background_store must write each image's bytes to DDR3 and
copy any of the 32 images back out byte by byte, address 0 up, in the order
written, whatever the controller's latency, with nothing lost, and stay inside
the 32 images' DDR3 space below the 128K planes.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
LOADER = REPO_ROOT / "rtl" / "input" / "nexttang_spec256_uart_loader.v"
RULES = REPO_ROOT / "rtl" / "video" / "nexttang_spec256_background_rules.v"
STORE = REPO_ROOT / "rtl" / "video" / "nexttang_spec256_background_store.v"

LOADER_TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, valid = 0;
    reg [7:0] byte_in = 0;
    wire payload, background_write, bgx_clear, bgx_write, bgx_wide, bgx_last;
    wire [4:0] background_image;
    wire [15:0] background_address;
    wire [7:0] background_index, bgx_data;
    wire [31:0] backgrounds_present;
    wire [12:0] bgx_index;
    wire [2:0] plane_bank;
    wire [7:0] banks_with_planes;
    integer bgx = 0, bgx_errors = 0, images = 0, image_errors = 0, clears = 0, i;
    integer lasts = 0, want_image = 2, wide_bytes = 0;
    reg checking = 1;

    nexttang_spec256_uart_loader dut (
        .clock(clock), .reset(reset), .byte_in(byte_in), .byte_valid(valid),
        .abort(1'b0), .payload(payload), .spec256_mode(),
        .plane_write(), .plane_address(), .plane_data(),
        .palette_write(), .palette_index(), .palette_rgb(),
        .arm(), .arm_pc(), .disarm(), .rules_flags(),
        .background_write(background_write), .background_image(background_image),
        .background_address(background_address), .background_index(background_index),
        .background_present(), .backgrounds_present(backgrounds_present),
        .bgx_clear(bgx_clear), .bgx_write(bgx_write), .bgx_wide(bgx_wide), .bgx_last(bgx_last),
        .bgx_index(bgx_index), .bgx_data(bgx_data),
        .cfg(), .rules(), .zxpoly_mode(), .paper_trim(),
        .plane_bank(plane_bank), .banks_with_planes(banks_with_planes));

    always #5 clock = ~clock;

    task send(input [7:0] b);
        begin
            @(negedge clock); byte_in = b; valid = 1;
            @(negedge clock); valid = 0;
        end
    endtask

    always @(posedge clock) begin
        if (bgx_clear) clears = clears + 1;
        if (bgx_write) begin
            if (checking) begin
                if (bgx_index !== bgx[12:0] || bgx_data !== ((bgx * 5 + 1) & 8'hff))
                    bgx_errors = bgx_errors + 1;
                bgx = bgx + 1;
            end else begin
                if (bgx_index !== wide_bytes[12:0]) bgx_errors = bgx_errors + 1;
                wide_bytes = wide_bytes + 1;
            end
        end
        if (bgx_last) lasts = lasts + 1;
        if (background_write) begin
            if (background_image !== want_image[4:0] || background_address !== images[15:0] ||
                background_index !== ((images * 3) & 8'hff))
                image_errors = image_errors + 1;
            images = images + 1;
        end
    end

    initial begin
        repeat (3) @(negedge clock); reset = 0;
        repeat (3) @(negedge clock);
        clears = 0;
        send("E");
        for (i = 0; i < 516; i = i + 1) send((i * 5 + 1) & 8'hff);
        if (payload !== 0) $fatal(1, "still in payload after E");
        send("M"); send("2");
        if (backgrounds_present !== 32'd0) $fatal(1, "M2 marked before its bytes");
        for (i = 0; i < 49152; i = i + 1) send((i * 3) & 8'hff);
        repeat (2) @(negedge clock);
        if (payload !== 0) $fatal(1, "still in payload after M2");
        if (backgrounds_present !== 32'b0100) $fatal(1, "M2 present %b", backgrounds_present);
        if (lasts !== 1) $fatal(1, "E: %0d last bytes", lasts);
        if (bgx_wide !== 0) $fatal(1, "E is not wide");

        // L with two rules: 4 + 128 bytes, then back to commands.
        checking = 0;
        send("L");
        send(1); send(2);
        if (bgx_wide !== 1) $fatal(1, "L is wide");
        for (i = 2; i < 132; i = i + 1) send(8'h55);
        repeat (2) @(negedge clock);
        if (payload !== 0) $fatal(1, "still in payload after L's two rules");
        if (lasts !== 2) $fatal(1, "L: %0d last bytes", lasts);
        if (wide_bytes !== 132) $fatal(1, "L passed %0d bytes", wide_bytes);
        wide_bytes = 0;

        // L with no rules is its header alone, and 64 rules 4100 bytes.
        send("L"); send(1); send(0); send(0); send(0);
        repeat (2) @(negedge clock);
        wide_bytes = 0;
        if (payload !== 0) $fatal(1, "still in payload after L with no rules");
        if (lasts !== 3) $fatal(1, "L with no rules: %0d last bytes", lasts);
        send("L"); send(1); send(64);
        for (i = 2; i < 4100; i = i + 1) begin
            if (payload !== 1) $fatal(1, "L with 64 rules ended at %0d", i);
            send(0);
        end
        repeat (2) @(negedge clock);
        if (payload !== 0) $fatal(1, "still in payload after L with 64 rules");
        if (lasts !== 4) $fatal(1, "L with 64 rules: %0d last bytes", lasts);
        if (wide_bytes !== 4100) $fatal(1, "L with 64 rules passed %0d bytes", wide_bytes);

        // A takes two hex digits, as far as background 31.
        want_image = 31;
        send("A"); send("1"); send("f");
        if (backgrounds_present[31] !== 0) $fatal(1, "A1f marked before its bytes");
        images = 0;
        for (i = 0; i < 49152; i = i + 1) send((i * 3) & 8'hff);
        repeat (2) @(negedge clock);
        if (payload !== 0) $fatal(1, "still in payload after A1f");
        if (backgrounds_present !== 32'h8000_0004) $fatal(1, "A1f present %h", backgrounds_present);
        want_image = 4;
        send("A"); send("0"); send("4");
        images = 0;
        for (i = 0; i < 49152; i = i + 1) send((i * 3) & 8'hff);
        repeat (2) @(negedge clock);
        if (backgrounds_present !== 32'h8000_0014) $fatal(1, "A04 present %h", backgrounds_present);
        send("P"); send("3"); send("P"); send("6"); send("P"); send("0");
        repeat (2) @(negedge clock);
        if (plane_bank !== 3'd0 || banks_with_planes !== 8'b0100_1001)
            $fatal(1, "P: bank %0d banks %b", plane_bank, banks_with_planes);
        send("P"); send("7");
        if (plane_bank !== 3'd7) $fatal(1, "P7 bank %0d", plane_bank);
        send("H");
        repeat (2) @(negedge clock);
        if (backgrounds_present !== 32'd0) $fatal(1, "H kept backgrounds %b", backgrounds_present);
        if (plane_bank !== 3'd0 || banks_with_planes !== 8'd0)
            $fatal(1, "H kept planes: bank %0d banks %b", plane_bank, banks_with_planes);
        $display("BGX errors %0d IMAGE %0d errors %0d CLEARS %0d",
                 bgx_errors, images, image_errors, clears);
        $finish;
    end
endmodule
"""

RULES_TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, clear = 0, load_write = 0, load_last = 0, running = 0, frame = 0, write = 0;
    reg [12:0] load_index = 0;
    reg [7:0] load_data = 0;
    reg [16:0] write_address = 0;
    reg [7:0] write_data = 0;
    wire valid;
    wire [5:0] selected;
    reg [7:0] image [0:515];
    integer i;

    nexttang_spec256_background_rules dut (
        .clock(clock), .reset(reset), .clear(clear),
        .load_write(load_write), .load_wide(1'b0), .load_last(load_last),
        .load_index(load_index), .load_data(load_data),
        .running(running), .frame(frame),
        .write(write), .write_address(write_address), .write_data(write_data),
        .valid(valid), .selected(selected), .overflow());

    always #5 clock = ~clock;

    // Condition c of rule r: address, test, mask, compare, initial value.
    task condition(input integer r, input integer c, input [16:0] address, input [7:0] test,
                   input [31:0] mask, input [31:0] compare, input [31:0] initial_value);
        integer base;
        begin
            base = 4 + 64 * r + 2 + 16 * c;
            image[base] = address[7:0]; image[base + 1] = address[15:8];
            image[base + 2] = {7'd0, address[16]}; image[base + 3] = test;
            for (i = 0; i < 4; i = i + 1) begin
                image[base + 4 + i] = mask[8*i +: 8];
                image[base + 8 + i] = compare[8*i +: 8];
                image[base + 12 + i] = initial_value[8*i +: 8];
            end
        end
    endtask

    task load;
        integer j;
        for (j = 0; j < 516; j = j + 1) begin
            @(negedge clock); load_write = 1; load_index = j; load_data = image[j];
            load_last = j == 515;
            @(negedge clock); load_write = 0; load_last = 0;
        end
    endtask

    task poke(input [16:0] address, input [7:0] data);
        begin
            @(negedge clock); write = 1; write_address = address; write_data = data;
            @(negedge clock); write = 0;
            repeat (4) @(negedge clock);
        end
    endtask

    task tick;
        begin
            @(negedge clock); frame = 1; @(negedge clock); frame = 0;
            repeat (540) @(negedge clock);
        end
    endtask

    task check(input [5:0] want, input [8*24-1:0] what);
        if (selected !== want) $fatal(1, "%0s: selected %0d, wanted %0d", what, selected, want);
    endtask

    initial begin
        for (i = 0; i < 516; i = i + 1) image[i] = 8'd0;
        // Game Over (Part 2)'s rules: attribute 0x5800 = 7 shows background
        // 1; bank 2 0x3EB2 below 5 shows 0; otherwise 1.
        image[0] = 1; image[1] = 2; image[2] = 1;
        image[4] = 1;
        condition(0, 0, 17'h15800, 8'h11, 32'hff, 32'h07, 32'h07);
        image[4 + 64] = 0;
        condition(1, 0, 17'h0beb2, 8'h31, 32'hff, 32'h05, 32'h01);
        repeat (3) @(negedge clock); reset = 0;
        load;
        if (valid !== 1) $fatal(1, "rules not valid after a load");
        tick; check(0, "not running");
        poke(17'h15800, 8'h38);          // not watched: not running
        running = 1;
        repeat (4) @(negedge clock);
        check(0, "before the first frame");
        tick; check(1, "attribute 7 at start");
        poke(17'h15800, 8'h38);
        check(1, "between frames");
        tick; check(0, "bank 2 value 1 below 5");
        poke(17'h0beb2, 8'h09);
        tick; check(1, "no rule: default 1");
        poke(17'h0beb2, 8'h04);
        tick; check(0, "back below 5");
        poke(17'h05800, 8'h07);          // bank 1, not bank 5
        tick; check(0, "another bank's write");
        running = 0;
        repeat (3) @(negedge clock);
        check(0, "stopped");

        // Hold (255), width 2, masks, >=, !=, 4 and the ignored 5.
        for (i = 0; i < 516; i = i + 1) image[i] = 8'd0;
        image[0] = 4; image[1] = 4; image[2] = 8'hff;
        image[4] = 2;
        condition(0, 0, 17'h1c000, 8'h12, 32'hffff, 32'h1234, 32'h0000);
        image[4 + 64] = 3;
        condition(1, 0, 17'h00100, 8'h41, 32'hf0, 32'h80, 32'h00);
        condition(1, 1, 17'h00101, 8'h21, 32'hff, 32'h00, 32'h00);
        image[4 + 128] = 5;
        condition(2, 0, 17'h00200, 8'h11, 32'hff, 32'h01, 32'h00);
        image[4 + 192] = 4;
        condition(3, 0, 17'h00300, 8'h11, 32'hff, 32'h01, 32'h00);
        load;
        running = 1;
        tick; check(0, "hold from the start");
        poke(17'h1c000, 8'h34);
        tick; check(0, "half the word");
        poke(17'h1c001, 8'h12);
        tick; check(2, "both bytes of the word");
        poke(17'h00100, 8'h8f);           // >= 0x80 after the mask, but 0x101 is 0
        poke(17'h1c001, 8'h00);
        tick; check(2, "!= not yet true: hold");
        poke(17'h00101, 8'h01);
        tick; check(3, ">= and !=");
        poke(17'h00100, 8'h0f);
        poke(17'h00200, 8'h01);
        tick; check(3, "5 ignored: hold");
        poke(17'h00300, 8'h01);
        tick; check(3, "rule 2 first, 5: hold");
        poke(17'h00200, 8'h00);
        tick; check(32, "rule 3: none shown");
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        repeat (3) @(negedge clock);
        if (valid !== 0) $fatal(1, "clear kept the rules");
        check(0, "cleared");
        $display("RULES PASS");
        $finish;
    end
endmodule
"""

BGX2_RULES_TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, clear = 0, load_write = 0, load_last = 0, load_wide = 1;
    reg running = 0, frame = 0, write = 0;
    reg [12:0] load_index = 0;
    reg [7:0] load_data = 0;
    reg [16:0] write_address = 0;
    reg [7:0] write_data = 0;
    wire valid, overflow;
    wire [5:0] selected;
    reg [7:0] image [0:4099];
    integer i, n, last_byte;

    nexttang_spec256_background_rules dut (
        .clock(clock), .reset(reset), .clear(clear),
        .load_write(load_write), .load_wide(load_wide), .load_last(load_last),
        .load_index(load_index), .load_data(load_data),
        .running(running), .frame(frame),
        .write(write), .write_address(write_address), .write_data(write_data),
        .valid(valid), .selected(selected), .overflow(overflow));

    always #5 clock = ~clock;

    task condition(input integer r, input integer c, input [16:0] address, input [7:0] test,
                   input [31:0] mask, input [31:0] compare, input [31:0] initial_value);
        integer base, k;
        begin
            base = 4 + 64 * r + 2 + 16 * c;
            image[base] = address[7:0]; image[base + 1] = address[15:8];
            image[base + 2] = {7'd0, address[16]}; image[base + 3] = test;
            for (k = 0; k < 4; k = k + 1) begin
                image[base + 4 + k] = mask[8*k +: 8];
                image[base + 8 + k] = compare[8*k +: 8];
                image[base + 12 + k] = initial_value[8*k +: 8];
            end
        end
    endtask

    task load(input integer rules);
        integer j, count;
        begin
            count = 4 + 64 * rules;
            for (j = 0; j < count; j = j + 1) begin
                @(negedge clock); load_write = 1; load_index = j; load_data = image[j];
                load_last = j == count - 1;
                @(negedge clock); load_write = 0; load_last = 0;
            end
        end
    endtask

    task poke(input [16:0] address, input [7:0] data);
        begin
            @(negedge clock); write = 1; write_address = address; write_data = data;
            @(negedge clock); write = 0;
            repeat (4) @(negedge clock);
        end
    endtask

    task tick;
        begin
            @(negedge clock); frame = 1; @(negedge clock); frame = 0;
            repeat (540) @(negedge clock);
        end
    endtask

    task check(input [5:0] want, input [8*32-1:0] what);
        if (selected !== want) $fatal(1, "%0s: selected %0d, wanted %0d", what, selected, want);
    endtask

    task wipe;
        for (i = 0; i < 4100; i = i + 1) image[i] = 8'd0;
    endtask

    initial begin
        // That Sinking Feeling's level byte, bank 5 offset 0x3D1B (32027),
        // with all seven of the original's backgrounds in play.
        wipe;
        image[0] = 3; image[1] = 8; image[2] = 8'hff;
        image[4 + 64*0] = 0; condition(0, 0, 17'h17d1b, 8'h11, 32'hff, 32'h19, 32'h19);
        image[4 + 64*1] = 1; condition(1, 0, 17'h17d1b, 8'h11, 32'hff, 32'h00, 32'h19);
        image[4 + 64*2] = 2; condition(2, 0, 17'h17d1b, 8'h11, 32'hff, 32'h04, 32'h19);
        image[4 + 64*3] = 3; condition(3, 0, 17'h17d1b, 8'h11, 32'hff, 32'h08, 32'h19);
        image[4 + 64*4] = 4; condition(4, 0, 17'h17d1b, 8'h11, 32'hff, 32'h0c, 32'h19);
        image[4 + 64*5] = 5; condition(5, 0, 17'h17d1b, 8'h11, 32'hff, 32'h10, 32'h19);
        image[4 + 64*6] = 6; condition(6, 0, 17'h17d1b, 8'h11, 32'hff, 32'h15, 32'h19);
        image[4 + 64*7] = 0; condition(7, 0, 17'h17d1b, 8'h11, 32'hff, 32'h17, 32'h19);
        repeat (3) @(negedge clock); reset = 0;
        load(8);
        if (valid !== 1) $fatal(1, "BGX2 not valid after a load");
        running = 1;
        tick; check(0, "first level");
        poke(17'h17d1b, 8'h00); tick; check(1, "level byte 00");
        poke(17'h17d1b, 8'h04); tick; check(2, "level byte 04");
        poke(17'h17d1b, 8'h08); tick; check(3, "level byte 08");
        poke(17'h17d1b, 8'h0c); tick; check(4, "level byte 0c");
        poke(17'h17d1b, 8'h10); tick; check(5, "level byte 10");
        poke(17'h17d1b, 8'h15); tick; check(6, "level byte 15");
        poke(17'h17d1b, 8'h17); tick; check(0, "level byte 17");
        poke(17'h17d1b, 8'h77); tick; check(0, "no rule: default keeps");
        poke(17'h17d1b, 8'h15); tick; check(6, "back to 6");
        poke(17'h17d1b, 8'h77); tick; check(6, "no rule: keeps 6, not 0");
        running = 0;

        // 64 rules over 16 watched values: rule n needs one of 8 values to read
        // n and one of 8 others to read n + 64. The walk reaches the end, every
        // rule works, and the shared values stay independent. Pictures run to
        // 31, the most there are: E = 28.
        wipe;
        image[0] = 28; image[1] = 64; image[2] = 8'hfe;
        for (n = 0; n < 64; n = n + 1) begin
            image[4 + 64*n] = n % 32;
            condition(n, 0, 17'h08000 + (n % 8), 8'h11, 32'hff, n, 32'hff);
            condition(n, 1, 17'h0c000 + (n % 8), 8'h11, 32'hff, n + 64, 32'hff);
        end
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        load(64);
        if (overflow !== 0) $fatal(1, "16 values overflowed");
        running = 1;
        tick; check(32, "64 rules: default none");
        for (n = 0; n < 64; n = n + 1) begin
            // One condition is not enough; both are.
            poke(17'h08000 + (n % 8), n);
            tick; check(32, "first condition alone: default");
            poke(17'h0c000 + (n % 8), n + 64);
            tick; check(n % 32, "both conditions");
            poke(17'h08000 + (n % 8), 8'hff);
            tick; check(32, "rule off: default none");
            poke(17'h08000 + (n % 8), n);
            poke(17'h0c000 + (n % 8), 8'hff);
            tick; check(32, "second condition off");
            poke(17'h0c000 + (n % 8), n + 64);
            tick; check(n % 32, "rule on again");
            poke(17'h08000 + (n % 8), 8'hff);
            poke(17'h0c000 + (n % 8), 8'hff);
        end
        running = 0;

        // A 17th watched value has no slot: its rule never holds, overflow says
        // so, and the rest work. A different width or starting value is a
        // different watched value; a rule with no test needs none.
        wipe;
        image[0] = 28; image[1] = 20; image[2] = 8'hfe;
        for (n = 0; n < 16; n = n + 1) begin
            image[4 + 64*n] = n;
            condition(n, 0, 17'h09000 + 16*n, 8'h11, 32'hff, 32'h01, 32'h00);
        end
        image[4 + 64*16] = 20; condition(16, 0, 17'h09000, 8'h11, 32'hff, 32'h02, 32'h00);  // shares slot 0
        image[4 + 64*17] = 21; condition(17, 0, 17'h09000, 8'h12, 32'hff, 32'h03, 32'h00);  // a 17th: width
        image[4 + 64*18] = 22; condition(18, 0, 17'h09010, 8'h11, 32'hff, 32'h04, 32'h09);  // an 18th: start
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        load(19);
        if (overflow !== 1) $fatal(1, "18 values did not overflow");
        running = 1;
        tick; check(32, "nothing true");
        poke(17'h09000 + 16*15, 8'h01); tick; check(15, "the 16th value works");
        poke(17'h09000 + 16*15, 8'h00); poke(17'h09000, 8'h02); tick; check(20, "a rule sharing slot 0");
        poke(17'h09000, 8'h03); tick; check(32, "no slot: never true (width)");
        poke(17'h09000, 8'h00); poke(17'h09010, 8'h04); tick; check(32, "no slot: never true (start)");
        running = 0;
        wipe;
        image[0] = 1; image[1] = 1; image[2] = 8'd2; image[4] = 8'd3;   // no test: always true
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        load(1);
        if (overflow !== 0) $fatal(1, "a clear must end the overflow");
        running = 1; tick; check(3, "a rule with no test holds"); running = 0;

        // The first true rule wins over later ones, and many conditions watch
        // one address and all see its writes at full speed: 64 rules, width 4,
        // with a write every 5 clocks, as a CPU at 28 MHz can push.
        wipe;
        image[0] = 28; image[1] = 64; image[2] = 8'hff;
        for (n = 0; n < 64; n = n + 1) begin
            image[4 + 64*n] = 8'd31 - (n % 28);
            condition(n, 0, 17'h14000, 8'h14, 32'hffff_ffff, 32'h0403_0201 + n, 32'h0);
        end
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        load(64);
        running = 1;
        tick; check(0, "nothing true yet");
        for (n = 0; n < 64; n = n + 1) begin
            @(negedge clock); write = 1; write_address = 17'h14000; write_data = 8'h01 + n;
            @(negedge clock); write = 0; repeat (3) @(negedge clock);
            @(negedge clock); write = 1; write_address = 17'h14001; write_data = 8'h02;
            @(negedge clock); write = 0; repeat (3) @(negedge clock);
            @(negedge clock); write = 1; write_address = 17'h14002; write_data = 8'h03;
            @(negedge clock); write = 0; repeat (3) @(negedge clock);
            @(negedge clock); write = 1; write_address = 17'h14003; write_data = 8'h04;
            @(negedge clock); write = 0; repeat (3) @(negedge clock);
            tick; check(31 - (n % 28), "the rule the word matches");
        end
        running = 0;

        // The first of two true rules; 0xFF keeps, 0xFE clears, a picture
        // past 3+E keeps; widths outside 1 to 4 and no rules at all.
        wipe;
        image[0] = 1; image[1] = 4; image[2] = 8'd1;       // pictures 0 to 4
        image[4 + 64*0] = 8'd4; condition(0, 0, 17'h00100, 8'h11, 32'hff, 32'h01, 32'h00);
        image[4 + 64*1] = 8'd3; condition(1, 0, 17'h00101, 8'h11, 32'hff, 32'h01, 32'h00);
        image[4 + 64*2] = 8'hfe; condition(2, 0, 17'h00102, 8'h11, 32'hff, 32'h01, 32'h00);
        image[4 + 64*3] = 8'd5; condition(3, 0, 17'h00103, 8'h11, 32'hff, 32'h01, 32'h00);
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        load(4);
        running = 1;
        tick; check(1, "default 1");
        poke(17'h00101, 8'h01); tick; check(3, "rule 1 alone");
        poke(17'h00100, 8'h01); tick; check(4, "rule 0 first, and 4 is real here");
        poke(17'h00100, 8'h00); poke(17'h00101, 8'h00); poke(17'h00102, 8'h01);
        tick; check(32, "fe: none");
        poke(17'h00102, 8'h00); tick; check(1, "default again");
        poke(17'h00103, 8'h01); tick; check(1, "5 is past 3+E: keeps");
        running = 0;

        wipe;
        image[0] = 1; image[1] = 0; image[2] = 8'd4;
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        load(0);
        if (valid !== 1) $fatal(1, "no rules at all is still a load");
        running = 1;
        tick; check(4, "no rules: the default");
        running = 0;
        repeat (3) @(negedge clock);
        check(0, "stopped");

        $display("BGX2 RULES PASS");
        $finish;
    end
endmodule
"""

STORE_TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, memory_clock = 0, reset = 1, memory_reset = 1;
    reg load_write = 0, copy_start = 0;
    reg [4:0] load_image = 0, copy_image = 0;
    reg [15:0] load_address = 0;
    reg [7:0] load_data = 0;
    wire lost, copy_busy, copy_write;
    wire [15:0] copy_address;
    wire [7:0] copy_data;
    wire request, command_enable, write_data_enable, write_data_end, burst;
    wire [2:0] command;
    wire [28:0] address;
    wire [255:0] write_data;
    wire [31:0] write_data_mask;
    reg command_ready = 0, write_data_ready = 0, read_valid = 0;
    reg [255:0] read_data = 0;
    reg [255:0] memory [0:65535];
    integer copied = 0, copy_errors = 0, order_errors = 0, i, n, latency = 0;
    reg [28:0] read_address;
    reg pending = 0;
    integer seed = 7;

    nexttang_spec256_background_store #(.BASE_BEAT('h20000)) dut (
        .clock(clock), .reset(reset),
        .load_write(load_write), .load_image(load_image), .load_address(load_address),
        .load_data(load_data), .lost(lost),
        .copy_start(copy_start), .copy_image(copy_image), .copy_busy(copy_busy),
        .copy_write(copy_write), .copy_address(copy_address), .copy_data(copy_data),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .controller_request(request), .controller_command_ready(command_ready),
        .controller_command(command), .controller_command_enable(command_enable),
        .controller_address(address), .controller_write_data_ready(write_data_ready),
        .controller_write_data(write_data), .controller_write_data_enable(write_data_enable),
        .controller_write_data_end(write_data_end), .controller_write_data_mask(write_data_mask),
        .controller_read_data(read_data), .controller_read_data_valid(read_valid),
        .controller_burst(burst));

    always #18 clock = ~clock;
    always #5 memory_clock = ~memory_clock;

    function [7:0] pattern(input integer image, input integer a);
        pattern = (a * 13 + a / 251 + image * 71) & 8'hff;
    endfunction

    // The controller: ready at random, reads answered after 8 to 40 cycles.
    always @(posedge memory_clock) begin
        command_ready <= !pending && ($random(seed) & 3) != 0;
        write_data_ready <= ($random(seed) & 1);
        read_valid <= 1'b0;
        if (command_enable && command_ready) begin
            if (address[2:0] != 3'b000 || address[28:3] < 26'h20000 || address[28:3] >= 26'h30000)
                $fatal(1, "address %h", address);
            if (command == 3'b000) begin
                if (!write_data_enable || write_data_mask != 32'd0 || !write_data_end)
                    $fatal(1, "write without its data");
                memory[address[28:3] - 26'h20000] <= write_data;
            end else begin
                pending <= 1'b1;
                read_address <= address;
                latency <= 8 + ($random(seed) & 31);
            end
        end
        if (pending) begin
            if (latency == 0) begin
                read_valid <= 1'b1;
                read_data <= memory[read_address[28:3] - 26'h20000];
                pending <= 1'b0;
            end else begin
                latency <= latency - 1;
            end
        end
    end

    reg [4:0] expect_image;
    always @(posedge clock)
        if (copy_write) begin
            if (copy_address !== copied[15:0]) order_errors = order_errors + 1;
            if (copy_data !== pattern(expect_image, copy_address)) copy_errors = copy_errors + 1;
            copied = copied + 1;
        end

    task load_image_bytes(input integer image);
        integer a;
        for (a = 0; a < 49152; a = a + 1) begin
            @(negedge clock);
            load_write = 1; load_image = image; load_address = a; load_data = pattern(image, a);
            @(negedge clock); load_write = 0;
            if (a % 32 == 31) repeat (12) @(negedge clock);
        end
    endtask

    task copy(input integer image);
        begin
            copied = 0; expect_image = image;
            @(negedge clock); copy_start = 1; copy_image = image;
            @(negedge clock); copy_start = 0;
            @(negedge clock);
            while (copy_busy) @(negedge clock);
            if (copied != 49152) $fatal(1, "image %0d copied %0d bytes", image, copied);
        end
    endtask

    integer started;
    initial begin
        repeat (4) @(negedge clock); reset = 0; memory_reset = 0;
        repeat (4) @(negedge clock);
        load_image_bytes(1);
        load_image_bytes(0);
        load_image_bytes(3);
        load_image_bytes(4);
        load_image_bytes(31);
        load_image_bytes(7);             // shares image 31's low three bits
        load_image_bytes(15);            // and image 31's low four
        repeat (40) @(negedge clock);
        started = $time;
        copy(3);
        $display("COPY took %0d us", ($time - started) / 1000);
        copy(0);
        copy(1);
        copy(31);
        copy(7);
        copy(15);
        copy(4);
        $display("STORE lost %0d copy_errors %0d order_errors %0d", lost, copy_errors, order_errors);
        $finish;
    end
endmodule
"""


class Spec256BackgroundsTest(unittest.TestCase):
    def test_loader_passes_bgx_rules_and_extra_backgrounds(self) -> None:
        output = run_testbench(LOADER_TESTBENCH, LOADER)
        self.assertIn("BGX errors 0 IMAGE 49152 errors 0 CLEARS 1", output, output)

    def test_rules_pick_backgrounds_as_spec256_mister(self) -> None:
        output = run_testbench(RULES_TESTBENCH, RULES)
        self.assertIn("RULES PASS", output, output)

    def test_bgx2_rules(self) -> None:
        output = run_testbench(BGX2_RULES_TESTBENCH, RULES)
        self.assertIn("BGX2 RULES PASS", output, output)

    def test_store_copies_each_image_back_in_order(self) -> None:
        output = run_testbench(STORE_TESTBENCH, STORE)
        self.assertIn("STORE lost 0 copy_errors 0 order_errors 0", output, output)
        took = int(output.split("COPY took ")[1].split(" us")[0])
        # The border between two pictures lasts 4.4 ms at 60 Hz.
        self.assertLess(took, 3000, output)


if __name__ == "__main__":
    unittest.main()
