// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A USB keyboard through the Tang Nano 20K's on-board BL616 running the
// FPGA-Companion firmware (github.com/harbaum/FPGA-Companion, Apache-2.0;
// protocol in its SPI.md, written here from that description).
//
// The BL616 is the SPI master (MODE 1: clock idles low, both sides shift out
// on the rising edge and sample on the falling edge, about 20 MHz) and the
// FPGA the target. Each message is framed by chip select and starts with a
// target byte and a command byte. This module answers just enough for the
// Companion to accept the FPGA and then takes its keyboard messages:
//
//   SYS (0) STATUS (0)   reply bytes 3-6: 7c 42 00 00. The Companion accepts
//                        an FPGA that answers 5c 42 and then runs its full
//                        start-up (SD card through the FPGA, config, OSD,
//                        menus), which this module does not serve; on Jon's
//                        board that start-up stopped after about 200 messages
//                        and no key was ever forwarded (2026-11-14, diagnostic
//                        log). With any other answer it treats the FPGA as not
//                        ready: it re-polls STATUS every 250 ms and its USB
//                        task still forwards keyboard input. NextNano answers
//                        7c 42 and its keyboard works on the same board, so
//                        this module answers the same. Every other request
//                        reads zeros.
//   HID (1) KEYBOARD (1) byte 2 is the USB HID usage code with bit 7 set on
//                        release; a modifier is 0x68 + its bit in the boot
//                        report (0x68 left control ... 0x6f right GUI).
//
//   HID (1) JOYSTICK (3) bytes 2 to 6: which joystick (0, 1, ...), the
//                        classic byte (bit 0 right, 1 left, 2 down, 3 up,
//                        4 to 7 fire buttons 1 to 4), analogue X and Y (not
//                        used here) and eight more buttons. Joystick 0 is
//                        given as the Next's left port and 1 as its right,
//                        in the core's order MODE X Z Y START A C B U D L R:
//                        fire 1 is B (the Kempston fire), fire 2 C, fire 3 A,
//                        fire 4 START, and the first four extra buttons Y, Z,
//                        X and MODE.
//   HID (1) MOUSE (2)    bytes 2 to 4: buttons (bit 0 left, 1 right, 2
//                        middle), movement right and movement down, signed;
//                        byte 5, when the mouse has a wheel, its movement.
//                        Kept here as the Kempston mouse's counters: X counts
//                        up to the right and Y up the screen, each wrapping
//                        at 256, and four bits of wheel.
//
// Both firmware lines send joystick and mouse messages in this form
// (FPGA-Companion's SPI.md and hid.c; checked 2026-11-17). Not yet tried
// with a real pad or mouse.
//
// Only byte 2 of a keyboard message is used. Two firmware lines send keys this way: upstream
// FPGA-Companion since 2026-10 follows byte 2 with a filler and PS/2 set-2
// codes, while the build NextNano ships for the on-board BL616 (RetroSilicon's
// FPGA-Companion-wip, from an older upstream) sends byte 2 alone. Reading the
// PS/2 bytes (until 2026-11-14) gives no keys with NextNano's firmware, which
// Jon's board most likely runs (it ran NextNano). Byte 2 keeps a boot-report
// image (modifier bits and up to six held usages) that
// nexttang_usb_keyboard_matrix turns into the forty-key matrix and F1-F10.
//
// The SPI side runs on the BL616's own clock: at 20 MHz there is half a
// clock period (25 ns) between the target seeing a byte boundary and the first
// bit of the reply, too little for an oversampled design at 28 MHz, so every
// reply depends only on the message's target, command and byte position, all
// known in the SPI clock domain. Received scan codes cross to `clock` by a
// toggle; bytes are 400 ns apart at 20 MHz, many clocks of `clock`.
//
// seen goes high once a STATUS request has been answered (the Companion is
// there and talking; it keeps polling STATUS); keyboard_message on each keyboard message received.

`default_nettype none

module nexttang_companion_keyboard (
    input  wire        clock,           // machine domain
    input  wire        reset,
    // the BL616's SPI
    input  wire        spi_cs_n,
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    output wire        spi_miso,
    // results, `clock` domain
    output wire [39:0] keys,
    output wire [10:1] function_keys,
    output reg         seen = 1'b0,
    output reg         keyboard_message = 1'b0,
    output wire [7:0]  message_byte,           // the usage byte, valid with keyboard_message
    // joysticks 0 and 1, active high: MODE X Z Y START A C B U D L R
    output wire [11:0] joystick_left,
    output wire [11:0] joystick_right,
    // the Kempston mouse's counters and buttons (middle, right, left)
    output reg  [7:0]  mouse_x = 8'd0,
    output reg  [7:0]  mouse_y = 8'd0,
    output reg  [2:0]  mouse_buttons = 3'd0,
    output reg  [3:0]  mouse_wheel = 4'd0
);
    // ---------------------------------------------------- SPI clock domain
    reg [2:0] bit_count = 3'd0;
    reg [3:0] byte_count = 4'd0;           // saturates at 15
    reg [6:0] shift_in = 7'd0;
    reg [7:0] target = 8'd0;
    reg [7:0] command = 8'd0;
    reg [7:0] rx_data = 8'd0;
    // what rx_data is: 1 a keyboard usage byte, 3 status answered; joystick
    // 4 its number, 5 the classic byte, 6 the extra buttons; mouse 8 buttons,
    // 9 movement right, 10 movement down, 11 wheel
    reg [3:0] rx_kind = 4'd0;
    reg       rx_toggle = 1'b0;

    wire [7:0] byte_in = {shift_in, spi_mosi};
    always @(negedge spi_sclk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            bit_count <= 3'd0;
            byte_count <= 4'd0;
        end else begin
            shift_in <= byte_in[6:0];
            bit_count <= bit_count + 3'd1;
            if (bit_count == 3'd7) begin
                if (byte_count != 4'd15) byte_count <= byte_count + 4'd1;
                if (byte_count == 4'd0) target <= byte_in;
                if (byte_count == 4'd1) command <= byte_in;
                // hand interesting bytes to the machine domain
                if (target == 8'd1 && command == 8'd1 && byte_count == 4'd2) begin
                    rx_data <= byte_in; rx_kind <= 4'd1; rx_toggle <= !rx_toggle;
                end else if (target == 8'd0 && command == 8'd0 && byte_count == 4'd6) begin
                    rx_data <= 8'd0; rx_kind <= 4'd3; rx_toggle <= !rx_toggle;
                end else if (target == 8'd1 && command == 8'd3 &&
                             (byte_count == 4'd2 || byte_count == 4'd3 || byte_count == 4'd6)) begin
                    rx_data <= byte_in; rx_toggle <= !rx_toggle;
                    rx_kind <= byte_count == 4'd2 ? 4'd4 : byte_count == 4'd3 ? 4'd5 : 4'd6;
                end else if (target == 8'd1 && command == 8'd2 && byte_count >= 4'd2 && byte_count <= 4'd5) begin
                    rx_data <= byte_in; rx_toggle <= !rx_toggle;
                    rx_kind <= 4'd6 + byte_count;       // 8 to 11
                end
            end
        end
    end

    // The reply byte for the byte about to start, from what the message has
    // said so far (target and command arrive in bytes 0 and 1).
    reg [7:0] reply;
    always @* begin
        reply = 8'h00;
        if (target == 8'd0 && command == 8'd0) begin
            case (byte_count)
                4'd3: reply = 8'h7c;            // see "STATUS" above: not 5c on purpose
                4'd4: reply = 8'h42;
                default: reply = 8'h00;     // core ID 0, cold boot flag 0
            endcase
        end
    end

    reg [6:0] shift_out = 7'd0;
    reg       miso_bit = 1'b0;
    always @(posedge spi_sclk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            miso_bit <= 1'b0;
        end else if (bit_count == 3'd0) begin
            miso_bit <= reply[7];
            shift_out <= reply[6:0];
        end else begin
            miso_bit <= shift_out[6];
            shift_out <= {shift_out[5:0], 1'b0};
        end
    end
    assign spi_miso = miso_bit;

    // ------------------------------------------------------ machine domain
    reg [2:0] toggle_sync = 3'b000;
    reg [7:0] modifiers = 8'd0;
    reg [6:0] held [0:5];                  // usages held down, 0 = empty slot
    integer   slot;
    reg       placed;
    initial for (slot = 0; slot < 6; slot = slot + 1) held[slot] = 7'd0;
    reg [7:0] joystick_number = 8'd0;
    reg [7:0] classic_0 = 8'd0, classic_1 = 8'd0;
    reg [3:0] extra_0 = 4'd0, extra_1 = 4'd0;
    // extra buttons 3..0 are MODE, X, Z, Y; fire 4..1 are START, A, C, B
    assign joystick_left = {extra_0[3], extra_0[2], extra_0[1], extra_0[0],
                            classic_0[7], classic_0[6], classic_0[5], classic_0[4],
                            classic_0[3], classic_0[2], classic_0[1], classic_0[0]};
    assign joystick_right = {extra_1[3], extra_1[2], extra_1[1], extra_1[0],
                             classic_1[7], classic_1[6], classic_1[5], classic_1[4],
                             classic_1[3], classic_1[2], classic_1[1], classic_1[0]};

    assign     message_byte = rx_data;
    wire       release_key = rx_data[7];
    wire [6:0] usage = rx_data[6:0];
    wire       is_modifier = usage[6:3] == 4'b1101;    // 0x68-0x6f

    always @(posedge clock) begin
        toggle_sync <= {toggle_sync[1:0], rx_toggle};
        keyboard_message <= 1'b0;
        if (reset) begin
            modifiers <= 8'd0;
            for (slot = 0; slot < 6; slot = slot + 1) held[slot] <= 7'd0;
            seen <= 1'b0;
        end else if (toggle_sync[2] != toggle_sync[1]) begin
            // rx_data and rx_kind have been still since the toggle moved
            case (rx_kind)
                4'd4: joystick_number <= rx_data;
                4'd5: if (joystick_number == 8'd0) classic_0 <= rx_data;
                      else if (joystick_number == 8'd1) classic_1 <= rx_data;
                4'd6: if (joystick_number == 8'd0) extra_0 <= rx_data[3:0];
                      else if (joystick_number == 8'd1) extra_1 <= rx_data[3:0];
                4'd8: mouse_buttons <= rx_data[2:0];
                4'd9: mouse_x <= mouse_x + rx_data;
                4'd10: mouse_y <= mouse_y - rx_data;
                4'd11: mouse_wheel <= mouse_wheel + rx_data[3:0];
                default: ;
            endcase
            if (rx_kind == 4'd3)
                seen <= 1'b1;
            else if (rx_kind == 4'd1) begin
                keyboard_message <= 1'b1;
                if (is_modifier)
                    modifiers[usage[2:0]] <= !release_key;
                else if (usage != 7'd0) begin
                    // a release clears every slot with this usage; a press
                    // takes the first free slot unless already held
                    placed = 1'b0;
                    for (slot = 0; slot < 6; slot = slot + 1) begin
                        if (held[slot] == usage) begin
                            if (release_key) held[slot] <= 7'd0;
                            placed = 1'b1;
                        end
                    end
                    if (!release_key && !placed) begin
                        for (slot = 0; slot < 6; slot = slot + 1) begin
                            if (!placed && held[slot] == 7'd0) begin
                                held[slot] <= usage;
                                placed = 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

    wire [10:1] decoded_function_keys;
    nexttang_usb_keyboard_matrix decode (
        .device_type(2'd1), .modifiers(modifiers),
        .key1({1'b0, held[0]}), .key2({1'b0, held[1]}), .key3({1'b0, held[2]}),
        .key4({1'b0, held[3]}), .key5({1'b0, held[4]}), .key6({1'b0, held[5]}),
        .keys(keys), .function_keys(decoded_function_keys));
    assign function_keys = decoded_function_keys;
endmodule

`default_nettype wire
