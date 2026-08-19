// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Bounded TZX player for the first tape-loading target. It intentionally
// supports only the three block types accepted by scripts/tzx_to_mem.py:
// text (0x30), standard-speed data (0x10) and turbo-speed data (0x11).
// Pulse lengths are T-states, so running this at the 3.5 MHz CPU clock keeps
// the tape edge timing independent of CPU WAIT states.

`default_nettype none

module nexttang_tzx_player #(
    parameter integer CLOCK_HZ = 3500000,
    parameter integer TZX_BYTES = 0,
    parameter IMAGE = "",
    parameter integer STANDARD_PILOT_LENGTH = 2168,
    parameter integer STANDARD_SYNC1_LENGTH = 667,
    parameter integer STANDARD_SYNC2_LENGTH = 735,
    parameter integer STANDARD_ZERO_LENGTH = 855,
    parameter integer STANDARD_ONE_LENGTH = 1710,
    parameter integer HEADER_PILOT_PULSES = 8063,
    parameter integer DATA_PILOT_PULSES = 3223
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        start,
    output reg         ear,
    output reg         active,
    output reg         finished,
    output reg         fault,
    output reg         fault_unsupported,
    output reg  [7:0]  current_block,
    output wire [16:0] byte_position,
    // The first four bytes shifted out as tape data, most significant first,
    // so a running board can be compared against the image it was built from.
    output reg  [31:0] first_data_bytes
);
    localparam integer CYCLES_PER_MS = CLOCK_HZ / 1000;
    localparam integer TAPE_ADDRESS_BITS = TZX_BYTES <= 1
        ? 1 : $clog2(TZX_BYTES);

    localparam [5:0] STATE_WAIT_START = 6'd0;
    localparam [5:0] STATE_HEADER = 6'd1;
    localparam [5:0] STATE_NEW_BLOCK = 6'd2;
    localparam [5:0] STATE_TEXT_LENGTH = 6'd3;
    localparam [5:0] STATE_SKIP = 6'd4;
    localparam [5:0] STATE_STANDARD_HEADER = 6'd5;
    localparam [5:0] STATE_TURBO_HEADER = 6'd6;
    localparam [5:0] STATE_FIRST_DATA = 6'd7;
    localparam [5:0] STATE_PILOT = 6'd8;
    localparam [5:0] STATE_PILOT_DONE = 6'd9;
    localparam [5:0] STATE_SYNC1 = 6'd10;
    localparam [5:0] STATE_SYNC2 = 6'd11;
    localparam [5:0] STATE_DATA_PULSE_A = 6'd12;
    localparam [5:0] STATE_DATA_PULSE_B = 6'd13;
    localparam [5:0] STATE_DATA_ADVANCE = 6'd14;
    localparam [5:0] STATE_NEXT_DATA = 6'd15;
    localparam [5:0] STATE_PAUSE_BEGIN = 6'd16;
    localparam [5:0] STATE_PAUSE = 6'd17;
    localparam [5:0] STATE_PULSE = 6'd18;
    localparam [5:0] STATE_DONE = 6'd19;

    localparam [1:0] FETCH_IDLE = 2'd0;
    localparam [1:0] FETCH_WAIT = 2'd1;
    localparam [1:0] FETCH_CAPTURE = 2'd2;

    reg [5:0] state;
    reg [5:0] pulse_return_state;
    reg [1:0] fetch_state;
    reg [16:0] next_byte_position;
    reg [TAPE_ADDRESS_BITS-1:0] rom_address;
    wire [7:0] rom_data;
    reg [7:0] fetched_byte;
    reg [2:0] first_data_seen;
    reg byte_valid;
    reg end_of_input;

    reg [4:0] field_index;
    reg [15:0] pause_ms;
    reg [15:0] pause_remaining;
    reg [31:0] pause_tick;
    reg [23:0] data_length;
    reg [23:0] bytes_after_current;
    reg [7:0] data_byte;
    reg [3:0] bits_remaining;
    reg [3:0] final_byte_bits;
    reg [15:0] pilot_length;
    reg [15:0] sync1_length;
    reg [15:0] sync2_length;
    reg [15:0] zero_length;
    reg [15:0] one_length;
    reg [15:0] pilot_remaining;
    reg [15:0] pulse_counter;
    reg [7:0] skip_remaining;
    reg turbo_block;

    assign byte_position = next_byte_position;

    nexttang_rom #(
        .ADDRESS_BITS(TAPE_ADDRESS_BITS),
        .IMAGE(IMAGE)
    ) tape_rom (
        .clock(clock),
        .address(rom_address),
        .data(rom_data)
    );

    wire state_needs_byte =
        state == STATE_HEADER || state == STATE_NEW_BLOCK ||
        state == STATE_TEXT_LENGTH || state == STATE_SKIP ||
        state == STATE_STANDARD_HEADER || state == STATE_TURBO_HEADER ||
        state == STATE_FIRST_DATA || state == STATE_NEXT_DATA;
    wire consume_byte = state_needs_byte && byte_valid;

    // The tape ROM is synchronous. Fetching therefore has an explicit wait
    // cycle before capture; the parser never consumes speculative data.
    always @(posedge clock) begin
        if (reset) begin
            fetch_state <= FETCH_IDLE;
            next_byte_position <= 0;
            rom_address <= 0;
            fetched_byte <= 0;
            byte_valid <= 1'b0;
            end_of_input <= 1'b0;
        end else begin
            if (consume_byte)
                byte_valid <= 1'b0;

            case (fetch_state)
                FETCH_IDLE: begin
                    if (state_needs_byte && !byte_valid) begin
                        if (next_byte_position >= TZX_BYTES) begin
                            end_of_input <= 1'b1;
                        end else begin
                            rom_address <= next_byte_position[
                                TAPE_ADDRESS_BITS-1:0
                            ];
                            fetch_state <= FETCH_WAIT;
                        end
                    end
                end

                FETCH_WAIT: begin
                    fetch_state <= FETCH_CAPTURE;
                end

                default: begin
                    fetched_byte <= rom_data;
                    byte_valid <= 1'b1;
                    next_byte_position <= next_byte_position + 1'b1;
                    fetch_state <= FETCH_IDLE;
                end
            endcase
        end
    end

    function [7:0] expected_header_byte(input [3:0] index);
        case (index)
            4'd0: expected_header_byte = "Z";
            4'd1: expected_header_byte = "X";
            4'd2: expected_header_byte = "T";
            4'd3: expected_header_byte = "a";
            4'd4: expected_header_byte = "p";
            4'd5: expected_header_byte = "e";
            4'd6: expected_header_byte = "!";
            4'd7: expected_header_byte = 8'h1a;
            4'd8: expected_header_byte = 8'h01;
            default: expected_header_byte = 8'h00;
        endcase
    endfunction

    always @(posedge clock) begin
        if (reset) begin
            state <= STATE_WAIT_START;
            pulse_return_state <= STATE_WAIT_START;
            ear <= 1'b0;
            active <= 1'b0;
            finished <= 1'b0;
            fault <= 1'b0;
            fault_unsupported <= 1'b0;
            current_block <= 0;
            field_index <= 0;
            pause_ms <= 0;
            pause_remaining <= 0;
            pause_tick <= 0;
            data_length <= 0;
            bytes_after_current <= 0;
            data_byte <= 0;
            first_data_bytes <= 0;
            first_data_seen <= 0;
            bits_remaining <= 0;
            final_byte_bits <= 8;
            pilot_length <= 0;
            sync1_length <= 0;
            sync2_length <= 0;
            zero_length <= 0;
            one_length <= 0;
            pilot_remaining <= 0;
            pulse_counter <= 0;
            skip_remaining <= 0;
            turbo_block <= 1'b0;
        end else begin
            if (end_of_input && state_needs_byte && !byte_valid) begin
                if (state == STATE_NEW_BLOCK) begin
                    state <= STATE_DONE;
                    active <= 1'b0;
                    finished <= 1'b1;
                    ear <= 1'b0;
                end else begin
                    state <= STATE_DONE;
                    active <= 1'b0;
                    finished <= 1'b1;
                    fault <= 1'b1;
                    ear <= 1'b0;
                end
            end else begin
                case (state)
                    STATE_WAIT_START: begin
                        if (start) begin
                            active <= 1'b1;
                            field_index <= 0;
                            state <= STATE_HEADER;
                        end
                    end

                    STATE_HEADER: begin
                        if (byte_valid) begin
                            if (field_index < 9 &&
                                fetched_byte != expected_header_byte(
                                    field_index[3:0]
                                )) begin
                                fault <= 1'b1;
                                active <= 1'b0;
                                finished <= 1'b1;
                                state <= STATE_DONE;
                            end else if (field_index == 9) begin
                                field_index <= 0;
                                state <= STATE_NEW_BLOCK;
                            end else begin
                                field_index <= field_index + 1'b1;
                            end
                        end
                    end

                    STATE_NEW_BLOCK: begin
                        if (byte_valid) begin
                            current_block <= fetched_byte;
                            field_index <= 0;
                            if (fetched_byte == 8'h00) begin
                                active <= 1'b0;
                                finished <= 1'b1;
                                ear <= 1'b0;
                                state <= STATE_DONE;
                            end else if (fetched_byte == 8'h30) begin
                                state <= STATE_TEXT_LENGTH;
                            end else if (fetched_byte == 8'h10) begin
                                turbo_block <= 1'b0;
                                pilot_length <= STANDARD_PILOT_LENGTH;
                                sync1_length <= STANDARD_SYNC1_LENGTH;
                                sync2_length <= STANDARD_SYNC2_LENGTH;
                                zero_length <= STANDARD_ZERO_LENGTH;
                                one_length <= STANDARD_ONE_LENGTH;
                                final_byte_bits <= 8;
                                state <= STATE_STANDARD_HEADER;
                            end else if (fetched_byte == 8'h11) begin
                                turbo_block <= 1'b1;
                                state <= STATE_TURBO_HEADER;
                            end else begin
                                fault <= 1'b1;
                                fault_unsupported <= 1'b1;
                                active <= 1'b0;
                                finished <= 1'b1;
                                state <= STATE_DONE;
                            end
                        end
                    end

                    STATE_TEXT_LENGTH: begin
                        if (byte_valid) begin
                            skip_remaining <= fetched_byte;
                            state <= fetched_byte == 0
                                ? STATE_NEW_BLOCK : STATE_SKIP;
                        end
                    end

                    STATE_SKIP: begin
                        if (byte_valid) begin
                            if (skip_remaining == 1) begin
                                skip_remaining <= 0;
                                state <= STATE_NEW_BLOCK;
                            end else begin
                                skip_remaining <= skip_remaining - 1'b1;
                            end
                        end
                    end

                    STATE_STANDARD_HEADER: begin
                        if (byte_valid) begin
                            case (field_index)
                                0: pause_ms[7:0] <= fetched_byte;
                                1: pause_ms[15:8] <= fetched_byte;
                                2: data_length[7:0] <= fetched_byte;
                                default: begin
                                    data_length[15:8] <= fetched_byte;
                                    data_length[23:16] <= 0;
                                    state <= STATE_FIRST_DATA;
                                end
                            endcase
                            field_index <= field_index + 1'b1;
                        end
                    end

                    STATE_TURBO_HEADER: begin
                        if (byte_valid) begin
                            case (field_index)
                                0: pilot_length[7:0] <= fetched_byte;
                                1: pilot_length[15:8] <= fetched_byte;
                                2: sync1_length[7:0] <= fetched_byte;
                                3: sync1_length[15:8] <= fetched_byte;
                                4: sync2_length[7:0] <= fetched_byte;
                                5: sync2_length[15:8] <= fetched_byte;
                                6: zero_length[7:0] <= fetched_byte;
                                7: zero_length[15:8] <= fetched_byte;
                                8: one_length[7:0] <= fetched_byte;
                                9: one_length[15:8] <= fetched_byte;
                                10: pilot_remaining[7:0] <= fetched_byte;
                                11: pilot_remaining[15:8] <= fetched_byte;
                                12: final_byte_bits <= fetched_byte[3:0];
                                13: pause_ms[7:0] <= fetched_byte;
                                14: pause_ms[15:8] <= fetched_byte;
                                15: data_length[7:0] <= fetched_byte;
                                16: data_length[15:8] <= fetched_byte;
                                default: begin
                                    data_length[23:16] <= fetched_byte;
                                    state <= STATE_FIRST_DATA;
                                end
                            endcase
                            field_index <= field_index + 1'b1;
                        end
                    end

                    STATE_FIRST_DATA: begin
                        if (byte_valid) begin
                            data_byte <= fetched_byte;
                            if (first_data_seen != 3'd4) begin
                                first_data_bytes <=
                                    {first_data_bytes[23:0], fetched_byte};
                                first_data_seen <= first_data_seen + 1'b1;
                            end
                            bits_remaining <= data_length == 1
                                ? final_byte_bits : 8;
                            bytes_after_current <= data_length - 1'b1;
                            if (!turbo_block)
                                pilot_remaining <= fetched_byte[7]
                                    ? DATA_PILOT_PULSES
                                    : HEADER_PILOT_PULSES;
                            state <= STATE_PILOT;
                        end
                    end

                    STATE_PILOT: begin
                        if (pilot_remaining == 0) begin
                            state <= STATE_SYNC1;
                        end else begin
                            pulse_counter <= pilot_length;
                            pulse_return_state <= STATE_PILOT_DONE;
                            state <= STATE_PULSE;
                        end
                    end

                    STATE_PILOT_DONE: begin
                        pilot_remaining <= pilot_remaining - 1'b1;
                        state <= STATE_PILOT;
                    end

                    STATE_SYNC1: begin
                        pulse_counter <= sync1_length;
                        pulse_return_state <= STATE_SYNC2;
                        state <= STATE_PULSE;
                    end

                    STATE_SYNC2: begin
                        pulse_counter <= sync2_length;
                        pulse_return_state <= STATE_DATA_PULSE_A;
                        state <= STATE_PULSE;
                    end

                    STATE_DATA_PULSE_A: begin
                        pulse_counter <= data_byte[7]
                            ? one_length : zero_length;
                        pulse_return_state <= STATE_DATA_PULSE_B;
                        state <= STATE_PULSE;
                    end

                    STATE_DATA_PULSE_B: begin
                        pulse_counter <= data_byte[7]
                            ? one_length : zero_length;
                        pulse_return_state <= STATE_DATA_ADVANCE;
                        state <= STATE_PULSE;
                    end

                    STATE_DATA_ADVANCE: begin
                        if (bits_remaining > 1) begin
                            data_byte <= {data_byte[6:0], 1'b0};
                            bits_remaining <= bits_remaining - 1'b1;
                            state <= STATE_DATA_PULSE_A;
                        end else if (bytes_after_current != 0) begin
                            state <= STATE_NEXT_DATA;
                        end else begin
                            state <= STATE_PAUSE_BEGIN;
                        end
                    end

                    STATE_NEXT_DATA: begin
                        if (byte_valid) begin
                            data_byte <= fetched_byte;
                            if (first_data_seen != 3'd4) begin
                                first_data_bytes <=
                                    {first_data_bytes[23:0], fetched_byte};
                                first_data_seen <= first_data_seen + 1'b1;
                            end
                            bits_remaining <= bytes_after_current == 1
                                ? final_byte_bits : 8;
                            bytes_after_current <= bytes_after_current - 1'b1;
                            state <= STATE_DATA_PULSE_A;
                        end
                    end

                    STATE_PAUSE_BEGIN: begin
                        // Do not drop the line here. The last pulse of a block
                        // has only just toggled it, so forcing it low now emits
                        // a two cycle pulse the ROM counts as a real edge, and
                        // that lands on the parity byte and fails the block.
                        // The line goes low a millisecond into the pause, which
                        // is what the upstream MiSTer player does.
                        pause_tick <= 0;
                        pause_remaining <= pause_ms;
                        state <= pause_ms == 0
                            ? STATE_NEW_BLOCK : STATE_PAUSE;
                    end

                    STATE_PAUSE: begin
                        if (pause_tick + 1 >= CYCLES_PER_MS) begin
                            pause_tick <= 0;
                            ear <= 1'b0;
                            if (pause_remaining == 1) begin
                                pause_remaining <= 0;
                                state <= STATE_NEW_BLOCK;
                            end else begin
                                pause_remaining <= pause_remaining - 1'b1;
                            end
                        end else begin
                            pause_tick <= pause_tick + 1'b1;
                        end
                    end

                    STATE_PULSE: begin
                        if (pulse_counter <= 1) begin
                            pulse_counter <= 0;
                            ear <= ~ear;
                            state <= pulse_return_state;
                        end else begin
                            pulse_counter <= pulse_counter - 1'b1;
                        end
                    end

                    default: begin
                        active <= 1'b0;
                        finished <= 1'b1;
                        state <= STATE_DONE;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
