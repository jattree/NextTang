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
//   SYS (0) STATUS (0)   reply bytes 3-6: 5c 42 00 00 (the signature the
//                        Companion polls for at start-up, core ID 0, no cold
//                        boot flag). Every other request reads zeros: no
//                        config XML, no interrupts, no joystick, no SD card
//                        (so the Companion never reaches the card).
//   HID (1) KEYBOARD (1) byte 2 is the USB HID usage code with bit 7 set on
//                        release, byte 3 a filler, and bytes 4 on the same key
//                        as PS/2 set-2 scan codes (E0 and F0 prefixes included).
//
// The scan codes go to nexttang_ps2_matrix, which keeps the forty-key matrix;
// F1 to F10 (usages 3a-43) are kept from the usage byte for the Next's hot
// keys. The SPI side runs on the BL616's own clock: at 20 MHz there is half a
// clock period (25 ns) between the target seeing a byte boundary and the first
// bit of the reply, too little for an oversampled design at 28 MHz, so every
// reply depends only on the message's target, command and byte position, all
// known in the SPI clock domain. Received scan codes cross to `clock` by a
// toggle; bytes are 400 ns apart at 20 MHz, many clocks of `clock`.
//
// seen goes high once a STATUS request has been answered (the Companion is
// there and talking); keyboard_message on each keyboard message received.

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
    output reg  [10:1] function_keys = 10'd0,
    output reg         seen = 1'b0,
    output reg         keyboard_message = 1'b0
);
    // ---------------------------------------------------- SPI clock domain
    reg [2:0] bit_count = 3'd0;
    reg [3:0] byte_count = 4'd0;           // saturates at 15
    reg [6:0] shift_in = 7'd0;
    reg [7:0] target = 8'd0;
    reg [7:0] command = 8'd0;
    reg [7:0] rx_data = 8'd0;
    reg [1:0] rx_kind = 2'd0;              // 1 usage byte, 2 scan code, 3 status answered
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
                end else if (target == 8'd1 && command == 8'd1 && byte_count >= 4'd4) begin
                    rx_data <= byte_in; rx_kind <= 2'd2; rx_toggle <= !rx_toggle;
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
                4'd3: reply = 8'h5c;
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
    reg [7:0] data_held = 8'd0;
    reg [1:0] kind_held = 2'd0;
    reg       scancode_valid = 1'b0;
    reg [7:0] scancode = 8'd0;
    always @(posedge clock) begin
        toggle_sync <= {toggle_sync[1:0], rx_toggle};
        scancode_valid <= 1'b0;
        keyboard_message <= 1'b0;
        if (reset) begin
            function_keys <= 10'd0;
            seen <= 1'b0;
        end else if (toggle_sync[2] != toggle_sync[1]) begin
            // rx_data and rx_kind have been still since the toggle moved
            case (rx_kind)
                2'd1: begin
                    keyboard_message <= 1'b1;
                    if (rx_data[6:0] >= 7'h3a && rx_data[6:0] <= 7'h43)
                        function_keys[rx_data[6:0] - 7'h39] <= !rx_data[7];
                end
                2'd2: begin scancode <= rx_data; scancode_valid <= 1'b1; end
                2'd3: seen <= 1'b1;
                default: ;
            endcase
        end
    end

    nexttang_ps2_matrix decode (
        .clock(clock), .reset(reset),
        .scancode(scancode), .scancode_valid(scancode_valid),
        .keys(keys));
endmodule

`default_nettype wire
