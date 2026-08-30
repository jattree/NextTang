// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Complete read-only storage service: SD SPI -> FAT32 volume -> directory or
// exact-length file byte stream. Only one high-level operation is active.
module nexttang_fat32_storage #(
    parameter integer CLOCK_HZ = 50_000_000
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        directory_start,
    input  wire [31:0] directory_cluster,
    input  wire        file_start,
    input  wire [31:0] file_cluster,
    input  wire [31:0] file_size,
    input  wire        file_pause,
    output wire        entry_valid,
    output wire [7:0]  entry_attributes,
    output wire [31:0] entry_cluster,
    output wire [31:0] entry_size,
    output wire [7:0]  entry_name_length,
    input  wire [7:0]  entry_name_index,
    output wire [7:0]  entry_name_data,
    output wire [7:0]  file_byte,
    output wire [31:0] file_offset,
    output wire        file_byte_valid,
    output reg         ready,
    output reg         busy,
    output reg         operation_done,
    output reg         error,
    output reg  [2:0]  diagnostic_code,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs
);
    localparam [2:0] WAIT_CARD=0, READ_VOLUME=1, IDLE=2,
                     READ_DIRECTORY=3, READ_FILE=4, FAILED=5;
    reg [2:0] state = WAIT_CARD;

    wire sd_ready, sd_busy, sd_error, sd_byte_valid, sd_done;
    wire [7:0] sd_byte;
    wire [8:0] sd_offset;
    reg sd_read_start = 0;
    reg [31:0] sd_sector = 0;

    reg volume_start = 0;
    wire volume_sector_start, volume_ready, volume_busy, volume_error;
    wire [1:0] volume_diagnostic;
    wire [31:0] volume_sector_lba, partition_lba, fat_lba, data_lba;
    wire [31:0] root_cluster, root_lba;
    wire [7:0] sectors_per_cluster;

    reg directory_go = 0;
    wire directory_sector_start, directory_busy, directory_done, directory_error;
    wire [31:0] directory_sector_lba;
    reg [31:0] selected_directory_cluster = 0;

    reg file_go = 0;
    wire file_sector_start, file_busy, file_done, file_error;
    wire [31:0] file_sector_lba;
    reg [31:0] selected_file_cluster = 0, selected_file_size = 0;

    nexttang_sd_spi_reader #(.CLOCK_HZ(CLOCK_HZ)) card (
        .clock(clock), .reset(reset), .read_start(sd_read_start), .sector(sd_sector),
        .ready(sd_ready), .busy(sd_busy), .error(sd_error),
        .byte_data(sd_byte), .byte_offset(sd_offset), .byte_valid(sd_byte_valid),
        .read_done(sd_done), .sd_clk(sd_clk), .sd_mosi(sd_mosi),
        .sd_miso(sd_miso), .sd_cs(sd_cs));

    nexttang_fat32_volume volume (
        .clock(clock), .reset(reset), .start(volume_start),
        .sector_start(volume_sector_start), .sector_lba(volume_sector_lba),
        .sector_ready(sd_ready), .sector_byte(sd_byte), .sector_offset(sd_offset),
        .sector_byte_valid(sd_byte_valid), .sector_done(sd_done),
        .sector_error(sd_error), .ready(volume_ready), .busy(volume_busy),
        .error(volume_error), .diagnostic_code(volume_diagnostic),
        .partition_lba(partition_lba),
        .sectors_per_cluster(sectors_per_cluster), .fat_lba(fat_lba),
        .data_lba(data_lba), .root_cluster(root_cluster), .root_lba(root_lba));

    nexttang_fat32_directory directory (
        .clock(clock), .reset(reset), .start(directory_go),
        .directory_cluster(selected_directory_cluster),
        .sectors_per_cluster(sectors_per_cluster), .fat_lba(fat_lba),
        .data_lba(data_lba), .sector_start(directory_sector_start),
        .sector_lba(directory_sector_lba), .sector_ready(sd_ready),
        .sector_byte(sd_byte), .sector_offset(sd_offset),
        .sector_byte_valid(sd_byte_valid), .sector_done(sd_done),
        .sector_error(sd_error), .entry_valid(entry_valid),
        .entry_attributes(entry_attributes), .entry_cluster(entry_cluster),
        .entry_size(entry_size), .entry_name_length(entry_name_length),
        .entry_name_index(entry_name_index), .entry_name_data(entry_name_data),
        .busy(directory_busy), .done(directory_done), .error(directory_error));

    nexttang_fat32_cluster_stream file_stream (
        .clock(clock), .reset(reset), .start(file_go), .abort(1'b0),
        .pause_requests(file_pause),
        .first_cluster(selected_file_cluster), .byte_limit(selected_file_size),
        .sectors_per_cluster(sectors_per_cluster), .fat_lba(fat_lba),
        .data_lba(data_lba), .sector_start(file_sector_start),
        .sector_lba(file_sector_lba), .sector_ready(sd_ready),
        .sector_byte(sd_byte), .sector_offset(sd_offset),
        .sector_byte_valid(sd_byte_valid), .sector_done(sd_done),
        .sector_error(sd_error), .stream_byte(file_byte),
        .stream_offset(file_offset), .stream_valid(file_byte_valid),
        .busy(file_busy), .done(file_done), .error(file_error));

    always @(posedge clock) begin
        if (reset) begin
            state <= WAIT_CARD; sd_read_start <= 0; sd_sector <= 0;
            volume_start <= 0; directory_go <= 0; file_go <= 0;
            selected_directory_cluster <= 0; selected_file_cluster <= 0;
            selected_file_size <= 0; ready <= 0; busy <= 1;
            operation_done <= 0; error <= 0;
            diagnostic_code <= 0;
        end else begin
            sd_read_start <= 0; volume_start <= 0; directory_go <= 0;
            file_go <= 0; operation_done <= 0;
            case (state)
                WAIT_CARD: begin
                    ready <= 0; busy <= 1;
                    if (sd_error) begin diagnostic_code <= 1; state <= FAILED; end
                    else if (sd_ready) begin volume_start <= 1; state <= READ_VOLUME; end
                end
                READ_VOLUME: begin
                    if (volume_sector_start) begin
                        sd_sector <= volume_sector_lba; sd_read_start <= 1;
                    end
                    if (volume_error) begin
                        diagnostic_code <= sd_error ? 3'd1 :
                                           volume_diagnostic == 2 ? 3'd6 :
                                           volume_diagnostic == 3 ? 3'd7 : 3'd2;
                        state <= FAILED;
                    end
                    else if (volume_ready) begin ready <= 1; busy <= 0; state <= IDLE; end
                end
                IDLE: begin
                    ready <= 1; busy <= 0;
                    if (directory_start) begin
                        selected_directory_cluster <= directory_cluster == 0 ?
                            root_cluster : directory_cluster;
                        directory_go <= 1; ready <= 0; busy <= 1;
                        state <= READ_DIRECTORY;
                    end else if (file_start) begin
                        selected_file_cluster <= file_cluster;
                        selected_file_size <= file_size;
                        file_go <= 1; ready <= 0; busy <= 1; state <= READ_FILE;
                    end
                end
                READ_DIRECTORY: begin
                    if (directory_sector_start) begin
                        sd_sector <= directory_sector_lba; sd_read_start <= 1;
                    end
                    if (directory_error) begin
                        diagnostic_code <= sd_error ? 3'd1 : 3'd3;
                        state <= FAILED;
                    end
                    else if (directory_done) begin
                        ready <= 1; busy <= 0; operation_done <= 1; state <= IDLE;
                    end
                end
                READ_FILE: begin
                    if (file_sector_start) begin
                        sd_sector <= file_sector_lba; sd_read_start <= 1;
                    end
                    if (file_error) begin
                        diagnostic_code <= sd_error ? 3'd1 : 3'd4;
                        state <= FAILED;
                    end
                    else if (file_done) begin
                        ready <= 1; busy <= 0; operation_done <= 1; state <= IDLE;
                    end
                end
                default: begin
                    ready <= 0; busy <= 0; error <= 1; state <= FAILED;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
