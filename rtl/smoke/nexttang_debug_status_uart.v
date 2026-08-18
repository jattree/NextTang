// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Sticky-event reporter over UART, for watching a bring-up that kills the video
// output. HDMI disappears the moment the video PLL drops lock, so anything that
// happens after that is invisible on screen. This keeps reporting as long as the
// system clock domain is alive, which is itself a useful signal: if lines keep
// arriving after the video PLL is lost, the FPGA and its 50 MHz domain are still
// running and the disturbance was local to the PLL. If the lines stop, or the
// tick counter restarts from zero, that points at a broader reset or a power
// event instead.
//
// Each flag is latched on its first assertion and never cleared, so a brief
// event cannot slip between lines. A flag that was seen and then went away
// reports '!', which is the whole point: it separates "never acquired" from
// "acquired and then lost".
//
// Line format, 115200 8N1:
//
//     NT V+ M+ R- C- 0001a2b3
//
//     +  asserted and still asserted      -  never seen      !  seen, then lost
//
// The trailing field is a free-running tick counter, so a stalled transmitter,
// a repeated line, or a restarted FPGA are all obvious from the log alone.

`default_nettype none

module nexttang_debug_status_uart #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD_RATE = 115200,
    parameter integer GAP_CLOCKS = 12500000    // a line every 0.25 s at 50 MHz
) (
    input  wire clock,
    input  wire reset,
    input  wire [5:0] flags,
    // {vsync_alive, pixel_clock_alive, calibration, released, memory, video}
    input  wire [31:0] value,   // reported verbatim, for a measured quantity
    output reg  transmit
);
    localparam integer MESSAGE_BYTES = 40;

    reg [5:0] seen = 0;
    reg [5:0] lost = 0;
    reg [31:0] tick = 0;

    always @(posedge clock) begin
        if (reset) begin
            seen <= 0;
            lost <= 0;
            tick <= 0;
        end else begin
            tick <= tick + 1'b1;
            seen <= seen | flags;
            lost <= lost | (seen & ~flags);
        end
    end

    function [7:0] state_character(input was_seen, input was_lost);
        state_character = was_lost ? "!" : was_seen ? "+" : "-";
    endfunction

    function [7:0] hex_digit(input [3:0] value);
        hex_digit = (value < 10) ? ("0" + value) : ("a" + value - 10);
    endfunction

    // The whole line is assembled once, at the moment transmission starts, and
    // then shifted out a byte at a time. Building it in one place keeps the
    // format readable and avoids indexing the message by position.
    wire [MESSAGE_BYTES*8-1:0] message = {
        "N", "T", " ",
        "V", state_character(seen[0], lost[0]), " ",
        "M", state_character(seen[1], lost[1]), " ",
        "R", state_character(seen[2], lost[2]), " ",
        "C", state_character(seen[3], lost[3]), " ",
        "P", state_character(seen[4], lost[4]), " ",
        "Y", state_character(seen[5], lost[5]), " ",
        hex_digit(tick[31:28]), hex_digit(tick[27:24]),
        hex_digit(tick[23:20]), hex_digit(tick[19:16]),
        hex_digit(tick[15:12]), hex_digit(tick[11:8]),
        hex_digit(tick[7:4]),   hex_digit(tick[3:0]), " ",
        hex_digit(value[31:28]), hex_digit(value[27:24]),
        hex_digit(value[23:20]), hex_digit(value[19:16]),
        hex_digit(value[15:12]), hex_digit(value[11:8]),
        hex_digit(value[7:4]),   hex_digit(value[3:0]),
        8'h0d, 8'h0a
    };

    reg [MESSAGE_BYTES*8-1:0] shift_message = 0;
    reg [7:0] bytes_left = 0;
    reg [3:0] bit_index = 0;
    reg [31:0] baud_accumulator = 0;
    reg [31:0] gap_counter = 0;
    reg [9:0] shifter = 10'h3ff;
    reg sending = 0;

    always @(posedge clock) begin
        if (reset) begin
            transmit <= 1'b1;
            sending <= 1'b0;
            bytes_left <= 0;
            bit_index <= 0;
            baud_accumulator <= 0;
            gap_counter <= 0;
            shifter <= 10'h3ff;
        end else if (!sending) begin
            transmit <= 1'b1;
            if (gap_counter == GAP_CLOCKS - 1) begin
                gap_counter <= 0;
                // Latch the line so a flag changing mid-transmission cannot
                // produce a half-old, half-new record.
                shift_message <= message << 8;
                shifter <= {1'b1, message[MESSAGE_BYTES*8-1 -: 8], 1'b0};
                bytes_left <= MESSAGE_BYTES - 1;
                bit_index <= 0;
                baud_accumulator <= 0;
                sending <= 1'b1;
            end else begin
                gap_counter <= gap_counter + 1'b1;
            end
        end else begin
            baud_accumulator <= baud_accumulator + BAUD_RATE;
            if (baud_accumulator + BAUD_RATE >= CLOCK_HZ) begin
                baud_accumulator <= baud_accumulator + BAUD_RATE - CLOCK_HZ;
                transmit <= shifter[0];
                shifter <= {1'b1, shifter[9:1]};
                if (bit_index == 9) begin
                    bit_index <= 0;
                    if (bytes_left == 0) begin
                        sending <= 1'b0;
                    end else begin
                        shifter <= {1'b1,
                                    shift_message[MESSAGE_BYTES*8-1 -: 8], 1'b0};
                        shift_message <= shift_message << 8;
                        bytes_left <= bytes_left - 1'b1;
                    end
                end else begin
                    bit_index <= bit_index + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
