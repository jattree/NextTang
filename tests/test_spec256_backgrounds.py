"""Spec256's BGX1 backgrounds: the loader's E, M and P commands, the rules, and the DDR3 store.

The loader passes E's 516 bytes on in order as BGX1 bytes and M's 49152 as
background n, marking it present once complete; H drops every background and
the rules (bgx_clear). P selects the bank W's 0xC000 words go to and marks
it as having planes; H returns to bank 0 and clears the marks.

nexttang_spec256_background_rules must pick backgrounds as SPEC256_MISTER
does: the first rule whose two conditions hold, else the default; only once a
frame; 255 or anything above 4 keeps the current one; a condition watches the
game's writes to its bytes (a two-byte condition takes its second byte from
the next address) and starts from the value the file gives; background 0
while not running or without rules, and writes made while not running are not
watched.

nexttang_spec256_background_store must write each image's bytes to DDR3 and
copy any image back out byte by byte, address 0 up, in the order written,
whatever the controller's latency, with nothing lost.
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
    wire payload, background_write, bgx_clear, bgx_write;
    wire [1:0] background_image;
    wire [15:0] background_address;
    wire [7:0] background_index, bgx_data;
    wire [3:0] backgrounds_present;
    wire [9:0] bgx_index;
    wire [2:0] plane_bank;
    wire [7:0] banks_with_planes;
    integer bgx = 0, bgx_errors = 0, images = 0, image_errors = 0, clears = 0, i;

    nexttang_spec256_uart_loader dut (
        .clock(clock), .reset(reset), .byte_in(byte_in), .byte_valid(valid),
        .abort(1'b0), .payload(payload), .spec256_mode(),
        .plane_write(), .plane_address(), .plane_data(),
        .palette_write(), .palette_index(), .palette_rgb(),
        .arm(), .arm_pc(), .disarm(), .rules_flags(),
        .background_write(background_write), .background_image(background_image),
        .background_address(background_address), .background_index(background_index),
        .background_present(), .backgrounds_present(backgrounds_present),
        .bgx_clear(bgx_clear), .bgx_write(bgx_write), .bgx_index(bgx_index), .bgx_data(bgx_data),
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
            if (bgx_index !== bgx[9:0] || bgx_data !== ((bgx * 5 + 1) & 8'hff))
                bgx_errors = bgx_errors + 1;
            bgx = bgx + 1;
        end
        if (background_write) begin
            if (background_image !== 2'd2 || background_address !== images[15:0] ||
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
        if (backgrounds_present !== 4'b0000) $fatal(1, "M2 marked before its bytes");
        for (i = 0; i < 49152; i = i + 1) send((i * 3) & 8'hff);
        repeat (2) @(negedge clock);
        if (payload !== 0) $fatal(1, "still in payload after M2");
        if (backgrounds_present !== 4'b0100) $fatal(1, "M2 present %b", backgrounds_present);
        send("P"); send("3"); send("P"); send("6"); send("P"); send("0");
        repeat (2) @(negedge clock);
        if (plane_bank !== 3'd0 || banks_with_planes !== 8'b0100_1001)
            $fatal(1, "P: bank %0d banks %b", plane_bank, banks_with_planes);
        send("P"); send("7");
        if (plane_bank !== 3'd7) $fatal(1, "P7 bank %0d", plane_bank);
        send("H");
        repeat (2) @(negedge clock);
        if (backgrounds_present !== 4'b0000) $fatal(1, "H kept backgrounds %b", backgrounds_present);
        if (plane_bank !== 3'd0 || banks_with_planes !== 8'd0)
            $fatal(1, "H kept planes: bank %0d banks %b", plane_bank, banks_with_planes);
        $display("BGX %0d errors %0d IMAGE %0d errors %0d CLEARS %0d",
                 bgx, bgx_errors, images, image_errors, clears);
        $finish;
    end
endmodule
"""

RULES_TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, clear = 0, load_write = 0, running = 0, frame = 0, write = 0;
    reg [9:0] load_index = 0;
    reg [7:0] load_data = 0;
    reg [16:0] write_address = 0;
    reg [7:0] write_data = 0;
    wire valid;
    wire [2:0] selected;
    reg [7:0] image [0:515];
    integer i;

    nexttang_spec256_background_rules dut (
        .clock(clock), .reset(reset), .clear(clear),
        .load_write(load_write), .load_index(load_index), .load_data(load_data),
        .running(running), .frame(frame),
        .write(write), .write_address(write_address), .write_data(write_data),
        .valid(valid), .selected(selected));

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
            @(negedge clock); load_write = 0;
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
            repeat (2) @(negedge clock);
        end
    endtask

    task check(input [2:0] want, input [8*24-1:0] what);
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
        tick; check(4, "rule 3: none shown");
        @(negedge clock); clear = 1; @(negedge clock); clear = 0;
        repeat (3) @(negedge clock);
        if (valid !== 0) $fatal(1, "clear kept the rules");
        check(0, "cleared");
        $display("RULES PASS");
        $finish;
    end
endmodule
"""

STORE_TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, memory_clock = 0, reset = 1, memory_reset = 1;
    reg load_write = 0, copy_start = 0;
    reg [1:0] load_image = 0, copy_image = 0;
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
    reg [255:0] memory [0:16383];
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
            if (address[2:0] != 3'b000 || address[28:3] < 26'h20000 || address[28:3] >= 26'h24000)
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

    reg [1:0] expect_image;
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
        repeat (40) @(negedge clock);
        started = $time;
        copy(3);
        $display("COPY took %0d us", ($time - started) / 1000);
        copy(0);
        copy(1);
        $display("STORE lost %0d copy_errors %0d order_errors %0d", lost, copy_errors, order_errors);
        $finish;
    end
endmodule
"""


class Spec256BackgroundsTest(unittest.TestCase):
    def test_loader_passes_bgx_rules_and_extra_backgrounds(self) -> None:
        output = run_testbench(LOADER_TESTBENCH, LOADER)
        self.assertIn("BGX 516 errors 0 IMAGE 49152 errors 0 CLEARS 1", output, output)

    def test_rules_pick_backgrounds_as_spec256_mister(self) -> None:
        output = run_testbench(RULES_TESTBENCH, RULES)
        self.assertIn("RULES PASS", output, output)

    def test_store_copies_each_image_back_in_order(self) -> None:
        output = run_testbench(STORE_TESTBENCH, STORE)
        self.assertIn("STORE lost 0 copy_errors 0 order_errors 0", output, output)
        took = int(output.split("COPY took ")[1].split(" us")[0])
        # The border between two pictures lasts 4.4 ms at 60 Hz.
        self.assertLess(took, 3000, output)


if __name__ == "__main__":
    unittest.main()
