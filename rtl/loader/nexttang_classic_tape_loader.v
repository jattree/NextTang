// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_classic_tape_loader #(
    parameter integer CLOCK_HZ=3500000,
    parameter integer STANDARD_PILOT_LENGTH=2168,
    parameter integer STANDARD_SYNC1_LENGTH=667,
    parameter integer STANDARD_SYNC2_LENGTH=735,
    parameter integer STANDARD_ZERO_LENGTH=855,
    parameter integer STANDARD_ONE_LENGTH=1710,
    parameter integer HEADER_PILOT_PULSES=8063,
    parameter integer DATA_PILOT_PULSES=3223
) (
    input wire write_clock,input wire write_reset,input wire content_start,
    input wire[2:0]content_format,input wire[7:0]content_byte,
    input wire content_valid,input wire content_done,output wire file_pause,
    input wire tape_clock,input wire tape_reset,input wire play_start,
    output wire ear,output wire active,
    output wire finished,output wire fault,output wire fault_unsupported
);
    localparam[2:0]FORMAT_TAP=1,FORMAT_TZX=2;
    wire[7:0]tap_byte;wire tap_valid,tap_done,tap_pause,tap_fault;
    wire is_tap=content_format==FORMAT_TAP;
    nexttang_tap_to_tzx_stream tap_converter(.clock(write_clock),.reset(write_reset),
        .start(content_start&&is_tap),.input_byte(content_byte),
        .input_valid(content_valid&&is_tap),.input_done(content_done&&is_tap),
        .output_byte(tap_byte),.output_valid(tap_valid),.output_done(tap_done),
        .pause_input(tap_pause),.fault(tap_fault));
    wire[7:0]tzx_byte=is_tap?tap_byte:content_byte;
    wire tzx_valid=is_tap?tap_valid:content_valid;
    wire tzx_done=is_tap?tap_done:content_done;
    wire fifo_pause,fifo_overflow,player_fault;
    assign file_pause=fifo_pause||(is_tap&&tap_pause);
    assign fault=player_fault||fifo_overflow||tap_fault||
                 (content_start&&content_format!=FORMAT_TAP&&content_format!=FORMAT_TZX);
    nexttang_tzx_stream #(.CLOCK_HZ(CLOCK_HZ),
        .STANDARD_PILOT_LENGTH(STANDARD_PILOT_LENGTH),
        .STANDARD_SYNC1_LENGTH(STANDARD_SYNC1_LENGTH),
        .STANDARD_SYNC2_LENGTH(STANDARD_SYNC2_LENGTH),
        .STANDARD_ZERO_LENGTH(STANDARD_ZERO_LENGTH),
        .STANDARD_ONE_LENGTH(STANDARD_ONE_LENGTH),
        .HEADER_PILOT_PULSES(HEADER_PILOT_PULSES),
        .DATA_PILOT_PULSES(DATA_PILOT_PULSES))stream(
        .write_clock(write_clock),.write_reset(write_reset),.content_start(content_start),
        .content_byte(tzx_byte),.content_valid(tzx_valid),.content_done(tzx_done),
        .file_pause(fifo_pause),.fifo_overflow(fifo_overflow),.tape_clock(tape_clock),
        .tape_reset(tape_reset),.play_start(play_start),.ear(ear),.active(active),.finished(finished),
        .fault(player_fault),.fault_unsupported(fault_unsupported));
endmodule

`default_nettype wire
