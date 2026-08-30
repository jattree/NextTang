// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Traverse one FAT32 directory cluster chain and decode its short/VFAT entries.
module nexttang_fat32_directory (
    input  wire        clock,
    input  wire        reset,
    input  wire        start,
    input  wire [31:0] directory_cluster,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_lba,
    input  wire [31:0] data_lba,
    output wire        sector_start,
    output wire [31:0] sector_lba,
    input  wire        sector_ready,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_offset,
    input  wire        sector_byte_valid,
    input  wire        sector_done,
    input  wire        sector_error,
    output wire        entry_valid,
    output wire [7:0]  entry_attributes,
    output wire [31:0] entry_cluster,
    output wire [31:0] entry_size,
    output wire [7:0]  entry_name_length,
    input  wire [7:0]  entry_name_index,
    output wire [7:0]  entry_name_data,
    output reg         busy,
    output reg         done,
    output reg         error
);
    wire [7:0] stream_byte;
    wire [31:0] stream_offset;
    wire stream_valid, stream_busy, stream_done, stream_error;
    reg stream_start = 0, stream_abort = 0;
    reg [255:0] raw_entry = 0;
    reg [4:0] byte_index = 0;
    reg decoder_start = 0, decoder_clear = 0, entry_pending = 0;
    wire decoder_busy, decoder_done, decoder_end;

    nexttang_fat32_cluster_stream stream (
        .clock(clock), .reset(reset), .start(stream_start), .abort(stream_abort),
        .pause_requests(1'b0),
        .first_cluster(directory_cluster), .byte_limit(32'b0),
        .sectors_per_cluster(sectors_per_cluster), .fat_lba(fat_lba),
        .data_lba(data_lba), .sector_start(sector_start), .sector_lba(sector_lba),
        .sector_ready(sector_ready), .sector_byte(sector_byte),
        .sector_offset(sector_offset), .sector_byte_valid(sector_byte_valid),
        .sector_done(sector_done), .sector_error(sector_error),
        .stream_byte(stream_byte), .stream_offset(stream_offset),
        .stream_valid(stream_valid), .busy(stream_busy), .done(stream_done),
        .error(stream_error));

    nexttang_fat32_directory_entry decoder (
        .clock(clock), .reset(reset), .clear(decoder_clear),
        .entry_start(decoder_start), .entry_data(raw_entry),
        .busy(decoder_busy), .entry_done(decoder_done), .file_valid(entry_valid),
        .end_directory(decoder_end), .attributes(entry_attributes),
        .first_cluster(entry_cluster), .file_size(entry_size),
        .name_length(entry_name_length), .name_index(entry_name_index),
        .name_data(entry_name_data));

    always @(posedge clock) begin
        if (reset) begin
            stream_start <= 0; stream_abort <= 0; raw_entry <= 0;
            byte_index <= 0; decoder_start <= 0; decoder_clear <= 0;
            entry_pending <= 0; busy <= 0; done <= 0; error <= 0;
        end else begin
            // Both controls are one-cycle requests.  In particular, leaving
            // stream_abort asserted after an end-of-directory marker would
            // make every subsequent directory scan terminate immediately.
            stream_start <= 0; stream_abort <= 0; decoder_start <= 0;
            decoder_clear <= 0; done <= 0;
            if (start && !busy) begin
                decoder_clear <= 1; stream_start <= 1; byte_index <= 0;
                entry_pending <= 0; busy <= 1; error <= 0;
            end
            if (stream_valid && busy) begin
                raw_entry[byte_index * 8 +: 8] <= stream_byte;
                if (byte_index == 31) begin
                    byte_index <= 0; entry_pending <= 1;
                end else byte_index <= byte_index + 1'b1;
            end
            if (entry_pending) begin
                if (decoder_busy) begin
                    error <= 1; stream_abort <= 1; entry_pending <= 0;
                end else begin
                    decoder_start <= 1; entry_pending <= 0;
                end
            end
            // decoder_end is a level which is cleared one cycle after a new
            // scan requests decoder_clear.  Do not let that stale level abort
            // the newly started cluster stream during the clear hand-off.
            if (decoder_end && busy && !decoder_clear) stream_abort <= 1;
            if (stream_error) error <= 1;
            if (stream_done && busy) begin
                busy <= 0; done <= 1;
                if (stream_error) error <= 1;
            end
        end
    end
endmodule

`default_nettype wire
