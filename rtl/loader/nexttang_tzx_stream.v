// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Bridge the 50 MHz SD/file stream to a real-time 3.5 MHz TZX waveform. The
// FIFO can absorb one complete in-flight sector after backpressure is raised.
module nexttang_tzx_stream #(
    parameter integer CLOCK_HZ=3500000,
    parameter integer STANDARD_PILOT_LENGTH=2168,
    parameter integer STANDARD_SYNC1_LENGTH=667,
    parameter integer STANDARD_SYNC2_LENGTH=735,
    parameter integer STANDARD_ZERO_LENGTH=855,
    parameter integer STANDARD_ONE_LENGTH=1710,
    parameter integer HEADER_PILOT_PULSES=8063,
    parameter integer DATA_PILOT_PULSES=3223
) (
    input  wire       write_clock,
    input  wire       write_reset,
    input  wire       content_start,
    input  wire [7:0] content_byte,
    input  wire       content_valid,
    input  wire       content_done,
    output wire       file_pause,
    output reg        fifo_overflow,
    input  wire       tape_clock,
    input  wire       tape_reset,
    // Kept separate from content_start: SD may fill the FIFO while the ROM
    // boots and the synthetic LOAD command is typed.  Starting any earlier
    // loses the pilot before the ROM is listening to EAR.
    input  wire       play_start,
    output wire       ear,
    output wire       active,
    output wire       finished,
    output wire       fault,
    output wire       fault_unsupported
);
    reg epoch=0,write_clear=0,writer_finished=0;
    wire fifo_full;wire[10:0]fifo_level;wire[7:0]fifo_data;
    wire fifo_valid,fifo_pop;
    reg epoch_r1=0,epoch_r2=0,epoch_seen=0;
    reg finished_r1=0,finished_r2=0;
    reg [2:0] restart_count=0;
    reg player_started=0;
    wire player_reset=tape_reset||!player_started||restart_count>1;
    wire player_start=restart_count==1;
    wire stream_ready;
    wire stream_end=finished_r2&&!fifo_valid;
    wire[7:0]current_block;wire[16:0]byte_position;wire[31:0]first_data_bytes;

    assign file_pause=fifo_level>=11'd512||fifo_full;
    assign fifo_pop=stream_ready&&fifo_valid;

    always @(posedge write_clock)begin
        if(write_reset)begin epoch<=0;write_clear<=0;writer_finished<=0;fifo_overflow<=0;end
        else begin
            write_clear<=0;
            if(content_start)begin epoch<=~epoch;write_clear<=1;
                writer_finished<=0;fifo_overflow<=0;end
            if(content_valid&&fifo_full)fifo_overflow<=1;
            if(content_done)writer_finished<=1;
        end
    end
    always @(posedge tape_clock)begin
        if(tape_reset)begin epoch_r1<=0;epoch_r2<=0;epoch_seen<=0;
            finished_r1<=0;finished_r2<=0;restart_count<=0;
            player_started<=0;end
        else begin
            epoch_r1<=epoch;epoch_r2<=epoch_r1;
            finished_r1<=writer_finished;finished_r2<=finished_r1;
            if(epoch_r2!=epoch_seen)begin epoch_seen<=epoch_r2;restart_count<=0;
                player_started<=0;end
            else if(play_start&&!player_started)begin restart_count<=3;
                player_started<=1;end
            else if(restart_count!=0)restart_count<=restart_count-1'b1;
        end
    end

    nexttang_async_byte_fifo fifo(
        .write_clock(write_clock),.write_reset(write_reset),.write_clear(write_clear),
        .write_data(content_byte),.write_enable(content_valid),.write_full(fifo_full),
        .write_level(fifo_level),.read_clock(tape_clock),.read_reset(tape_reset),
        .read_clear(epoch_r2!=epoch_seen),.read_data(fifo_data),
        .read_valid(fifo_valid),.read_pop(fifo_pop));

    nexttang_tzx_player #(.CLOCK_HZ(CLOCK_HZ),.EXTERNAL_STREAM(1),.TZX_BYTES(0),
        .STANDARD_PILOT_LENGTH(STANDARD_PILOT_LENGTH),
        .STANDARD_SYNC1_LENGTH(STANDARD_SYNC1_LENGTH),
        .STANDARD_SYNC2_LENGTH(STANDARD_SYNC2_LENGTH),
        .STANDARD_ZERO_LENGTH(STANDARD_ZERO_LENGTH),
        .STANDARD_ONE_LENGTH(STANDARD_ONE_LENGTH),
        .HEADER_PILOT_PULSES(HEADER_PILOT_PULSES),
        .DATA_PILOT_PULSES(DATA_PILOT_PULSES)) player(
        .clock(tape_clock),.reset(player_reset),.start(player_start),
        .stream_data(fifo_data),.stream_valid(fifo_valid),.stream_end(stream_end),
        .stream_ready(stream_ready),.ear(ear),.active(active),.finished(finished),
        .fault(fault),.fault_unsupported(fault_unsupported),
        .current_block(current_block),.byte_position(byte_position),
        .first_data_bytes(first_data_bytes));
endmodule

`default_nettype wire
