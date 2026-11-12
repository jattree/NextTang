// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// nexttang_companion_keyboard against an SPI master that frames messages the
// way FPGA-Companion's firmware does (SPI MODE 1 at 20 MHz): the STATUS poll
// must read 5c 42 00 00, and keyboard messages (usage byte, filler, PS/2 set-2
// codes) must set and clear matrix keys and F-keys.
`timescale 1ns/1ps
`default_nettype none
module tb_companion_keyboard;
    reg clock = 1'b0;
    always #17.778 clock = !clock;            // 28.125 MHz
    reg reset = 1'b1;
    reg cs_n = 1'b1, sclk = 1'b0, mosi = 1'b0;
    wire miso;
    wire [39:0] keys;
    wire [10:1] fkeys;
    wire seen, kmsg;
    nexttang_companion_keyboard dut (
        .clock(clock), .reset(reset),
        .spi_cs_n(cs_n), .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(miso),
        .keys(keys), .function_keys(fkeys), .seen(seen), .keyboard_message(kmsg));

    integer errors = 0;
    reg [7:0] got;
    // MODE 1: shift out on the rising edge, sample on the falling edge
    task xfer(input [7:0] tx, output [7:0] rx);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                #25 sclk = 1'b1; mosi = tx[b];
                #25 sclk = 1'b0; rx[b] = miso;
            end
        end
    endtask
    task begin_msg; begin cs_n = 1'b0; #40; end endtask
    task end_msg; begin #40 cs_n = 1'b1; #200; end endtask
    task send(input [7:0] b); begin xfer(b, got); end endtask

    task key_message(input [7:0] usage, input [7:0] c0, input [7:0] c1, input [7:0] c2, input integer n);
        begin
            begin_msg; send(8'd1); send(8'd1); send(usage); send(usage);
            if (n > 0) send(c0);
            if (n > 1) send(c1);
            if (n > 2) send(c2);
            end_msg; #600;
        end
    endtask

    reg [7:0] r [0:6];
    integer i;
    initial begin
        #200 reset = 1'b0; #200;
        // STATUS poll, as sys_status_is_valid: target, command, then five bytes
        begin_msg;
        for (i = 0; i < 7; i = i + 1) xfer(i < 2 ? 8'd0 : 8'd0, r[i]);
        end_msg; #400;
        if (r[3] !== 8'h5c || r[4] !== 8'h42 || r[5] !== 8'h00 || r[6] !== 8'h00) begin
            $display("FAIL status reply %h %h %h %h", r[3], r[4], r[5], r[6]); errors = errors + 1;
        end
        if (!seen) begin $display("FAIL seen not set"); errors = errors + 1; end
        // config read returns no '<' (no XML)
        begin_msg; send(8'd0); send(8'd8); send(8'd0); xfer(8'd0, got); end_msg;
        if (got === 8'h3c) begin $display("FAIL config read looks like XML"); errors = errors + 1; end

        // A: usage 04, PS/2 1c; release 84, F0 1c
        key_message(8'h04, 8'h1c, 8'h00, 8'h00, 1);
        if (keys[5] !== 1'b1) begin $display("FAIL A not pressed (keys %h)", keys); errors = errors + 1; end
        key_message(8'h84, 8'hf0, 8'h1c, 8'h00, 2);
        if (keys !== 40'd0) begin $display("FAIL A not released (keys %h)", keys); errors = errors + 1; end
        // SPACE (row 7 col 0 = bit 35): usage 2c, PS/2 29
        key_message(8'h2c, 8'h29, 8'h00, 8'h00, 1);
        if (keys[35] !== 1'b1) begin $display("FAIL SPACE not pressed"); errors = errors + 1; end
        key_message(8'hac, 8'hf0, 8'h29, 8'h00, 2);
        // left shift as a modifier (0x68 + bit 1), PS/2 12: caps shift (bit 0)
        key_message(8'h69, 8'h12, 8'h00, 8'h00, 1);
        if (keys[0] !== 1'b1) begin $display("FAIL caps shift not pressed (keys %h)", keys); errors = errors + 1; end
        key_message(8'he9, 8'hf0, 8'h12, 8'h00, 2);
        // cursor up: usage 52, E0 75 (caps shift + 7)
        key_message(8'h52, 8'he0, 8'h75, 8'h00, 2);
        if (keys[0] !== 1'b1 || keys[23] !== 1'b1) begin $display("FAIL up arrow (keys %h)", keys); errors = errors + 1; end
        key_message(8'hd2, 8'he0, 8'hf0, 8'h75, 3);
        if (keys !== 40'd0) begin $display("FAIL up arrow not released (keys %h)", keys); errors = errors + 1; end
        // F1: usage 3a, PS/2 05
        key_message(8'h3a, 8'h05, 8'h00, 8'h00, 1);
        if (fkeys !== 10'b0000000001) begin $display("FAIL F1 not held (%b)", fkeys); errors = errors + 1; end
        key_message(8'hba, 8'hf0, 8'h05, 8'h00, 2);
        if (fkeys !== 10'd0) begin $display("FAIL F1 not released"); errors = errors + 1; end
        // a message to another target must not disturb the keys
        begin_msg; send(8'd2); send(8'd2); send(8'd0); send(8'h1c); end_msg;
        if (keys !== 40'd0) begin $display("FAIL OSD message reached the keys"); errors = errors + 1; end

        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end
endmodule
`default_nettype wire
