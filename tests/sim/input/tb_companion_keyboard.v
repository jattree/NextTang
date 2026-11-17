// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// nexttang_companion_keyboard against an SPI master that frames messages the
// way FPGA-Companion's firmware does (SPI MODE 1 at 20 MHz): the STATUS poll
// must read 7c 42 00 00, and keyboard messages must set and clear matrix keys
// and F-keys in both formats the firmware lines use: byte 2 alone (NextNano's
// on-board BL616 build) and byte 2, filler, PS/2 set-2 codes (upstream).
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
        .keys(keys), .function_keys(fkeys), .seen(seen), .keyboard_message(kmsg),
        .joystick_left(joy_left), .joystick_right(joy_right),
        .mouse_x(mouse_x), .mouse_y(mouse_y), .mouse_buttons(mouse_buttons), .mouse_wheel(mouse_wheel));
    wire [11:0] joy_left, joy_right;
    wire [7:0]  mouse_x, mouse_y;
    wire [2:0]  mouse_buttons;
    wire [3:0]  mouse_wheel;
    task joystick_message(input [7:0] number, input [7:0] classic, input [7:0] extra);
        begin
            begin_msg; send(8'd1); send(8'd3); send(number); send(classic);
            send(8'h80); send(8'h80); send(extra); end_msg; #600;
        end
    endtask
    task mouse_message(input [7:0] buttons, input [7:0] dx, input [7:0] dy, input integer wheel, input [7:0] dw);
        begin
            begin_msg; send(8'd1); send(8'd2); send(buttons); send(dx); send(dy);
            if (wheel) send(dw);
            end_msg; #600;
        end
    endtask

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

    task short_key(input [7:0] code);
        begin begin_msg; send(8'd1); send(8'd1); send(code); end_msg; #600; end
    endtask

    reg [7:0] r [0:6];
    integer i;
    initial begin
        #200 reset = 1'b0; #200;
        // STATUS poll, as sys_status_is_valid: target, command, then five bytes
        begin_msg;
        for (i = 0; i < 7; i = i + 1) xfer(i < 2 ? 8'd0 : 8'd0, r[i]);
        end_msg; #400;
        if (r[3] !== 8'h7c || r[4] !== 8'h42 || r[5] !== 8'h00 || r[6] !== 8'h00) begin
            $display("FAIL status reply %h %h %h %h", r[3], r[4], r[5], r[6]); errors = errors + 1;
        end
        if (!seen) begin $display("FAIL seen not set"); errors = errors + 1; end
        // config read returns no '<' (no XML)
        begin_msg; send(8'd0); send(8'd8); send(8'd0); xfer(8'd0, got); end_msg;
        if (got === 8'h3c) begin $display("FAIL config read looks like XML"); errors = errors + 1; end

        // ---- upstream format: usage, filler, PS/2 codes
        // A: usage 04, PS/2 1c; release 84, F0 1c
        key_message(8'h04, 8'h1c, 8'h00, 8'h00, 1);
        if (keys[5] !== 1'b1) begin $display("FAIL A not pressed (keys %h)", keys); errors = errors + 1; end
        key_message(8'h84, 8'hf0, 8'h1c, 8'h00, 2);
        if (keys !== 40'd0) begin $display("FAIL A not released (keys %h)", keys); errors = errors + 1; end
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

        // ---- NextNano's format: [1][1][usage | release bit], nothing else
        short_key(8'h28);                                   // ENTER (bit 30)
        if (keys[30] !== 1'b1) begin $display("FAIL short ENTER not pressed (keys %h)", keys); errors = errors + 1; end
        short_key(8'h2c);                                   // SPACE too (bit 35)
        if (keys[30] !== 1'b1 || keys[35] !== 1'b1) begin $display("FAIL two keys held (keys %h)", keys); errors = errors + 1; end
        short_key(8'ha8);                                   // release ENTER only
        if (keys[30] !== 1'b0 || keys[35] !== 1'b1) begin $display("FAIL release one of two (keys %h)", keys); errors = errors + 1; end
        short_key(8'hac);
        if (keys !== 40'd0) begin $display("FAIL short keys not released (keys %h)", keys); errors = errors + 1; end
        short_key(8'h68);                                   // left control = symbol shift (bit 36)
        short_key(8'h13);                                   // P (bit 25): symbol shift + P is "
        if (keys[36] !== 1'b1 || keys[25] !== 1'b1) begin $display("FAIL symbol shift + P (keys %h)", keys); errors = errors + 1; end
        short_key(8'h93); short_key(8'he8);
        if (keys !== 40'd0) begin $display("FAIL symbol shift + P not released (keys %h)", keys); errors = errors + 1; end
        short_key(8'h69);                                   // left shift = caps shift (bit 0)
        if (keys[0] !== 1'b1) begin $display("FAIL short caps shift (keys %h)", keys); errors = errors + 1; end
        short_key(8'he9);
        short_key(8'h43);                                   // F10
        if (fkeys !== 10'b1000000000) begin $display("FAIL short F10 (%b)", fkeys); errors = errors + 1; end
        short_key(8'hc3);
        // a repeated press must not take a second slot; one release clears it
        short_key(8'h04); short_key(8'h04); short_key(8'h84);
        if (keys !== 40'd0 || fkeys !== 10'd0) begin $display("FAIL repeated press (keys %h)", keys); errors = errors + 1; end
        // a message to another target must not disturb the keys
        begin_msg; send(8'd2); send(8'd2); send(8'd0); send(8'h1c); end_msg;
        if (keys !== 40'd0) begin $display("FAIL OSD message reached the keys"); errors = errors + 1; end

        // ---- joysticks: 0 is the left port, 1 the right
        joystick_message(8'd0, 8'h11, 8'h00);               // right + fire 1
        if (joy_left !== 12'h011 || joy_right !== 12'h000) begin $display("FAIL joystick 0 right+fire (%h %h)", joy_left, joy_right); errors = errors + 1; end
        joystick_message(8'd1, 8'h8a, 8'h09);               // left, up, fire 4; extra buttons 0 and 3
        if (joy_left !== 12'h011 || joy_right !== 12'h98a) begin $display("FAIL joystick 1 (%h %h)", joy_left, joy_right); errors = errors + 1; end
        joystick_message(8'd0, 8'h00, 8'h00);
        joystick_message(8'd2, 8'hff, 8'hff);               // a third pad is ignored
        if (joy_left !== 12'h000 || joy_right !== 12'h98a) begin $display("FAIL joystick release / third pad (%h %h)", joy_left, joy_right); errors = errors + 1; end
        joystick_message(8'd1, 8'h00, 8'h00);
        if (keys !== 40'd0) begin $display("FAIL joystick reached the keys"); errors = errors + 1; end

        // ---- mouse: right 5 and down 3, then left 10 and up 4 with a wheel
        mouse_message(8'h01, 8'd5, 8'd3, 0, 8'd0);
        if (mouse_x !== 8'd5 || mouse_y !== 8'hfd || mouse_buttons !== 3'b001) begin $display("FAIL mouse 1 (%h %h %b)", mouse_x, mouse_y, mouse_buttons); errors = errors + 1; end
        mouse_message(8'h06, 8'hf6, 8'hfc, 1, 8'h01);
        if (mouse_x !== 8'hfb || mouse_y !== 8'h01 || mouse_buttons !== 3'b110 || mouse_wheel !== 4'd1) begin $display("FAIL mouse 2 (%h %h %b %h)", mouse_x, mouse_y, mouse_buttons, mouse_wheel); errors = errors + 1; end
        if (keys !== 40'd0 || joy_left !== 12'd0) begin $display("FAIL mouse reached keys or joystick"); errors = errors + 1; end

        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end
endmodule
`default_nettype wire
