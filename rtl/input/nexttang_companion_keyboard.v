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
// Only byte 2 is used. Two firmware lines send keys this way: upstream
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
    output wire [7:0]  message_byte            // the usage byte, valid with keyboard_message
);
    // ---------------------------------------------------- SPI clock domain
    reg [2:0] bit_count = 3'd0;
    reg [3:0] byte_count = 4'd0;           // saturates at 15
    reg [6:0] shift_in = 7'd0;
    reg [7:0] target = 8'd0;
    reg [7:0] command = 8'd0;
    reg [7:0] rx_data = 8'd0;
    reg [1:0] rx_kind = 2'd0;              // 1 usage byte, 3 status answered
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
                    rx_data <= byte_in; rx_kind <= 2'd1; rx_toggle <= !rx_toggle;
                end else if (target == 8'd0 && command == 8'd0 && byte_count == 4'd6) begin
                    rx_data <= 8'd0; rx_kind <= 2'd3; rx_toggle <= !rx_toggle;
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
            if (rx_kind == 2'd3)
                seen <= 1'b1;
            else if (rx_kind == 2'd1) begin
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
