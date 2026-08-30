// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Locate an MBR-partitioned or superfloppy FAT32 volume and expose the geometry
// needed by a directory walker. This layer is deliberately read-only.
module nexttang_fat32_volume (
    input  wire        clock,
    input  wire        reset,
    input  wire        start,
    output reg         sector_start,
    output reg  [31:0] sector_lba,
    input  wire        sector_ready,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_offset,
    input  wire        sector_byte_valid,
    input  wire        sector_done,
    input  wire        sector_error,
    output reg         ready,
    output reg         busy,
    output reg         error,
    output reg  [1:0]  diagnostic_code,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_lba,
    output reg  [31:0] data_lba,
    output reg  [31:0] root_cluster,
    output reg  [31:0] root_lba
);
    reg [7:0] buffer [0:511];
    reg reading_boot = 0;
    reg [15:0] reserved_sectors;
    reg [7:0] fat_count;
    reg [31:0] fat_sectors;
    integer index;

    function [15:0] le16;
        input integer offset;
        begin le16 = {buffer[offset + 1], buffer[offset]}; end
    endfunction
    function [31:0] le32;
        input integer offset;
        begin le32 = {buffer[offset + 3], buffer[offset + 2],
                      buffer[offset + 1], buffer[offset]}; end
    endfunction

    task request_sector;
        input [31:0] lba;
        begin sector_lba <= lba; sector_start <= 1; end
    endtask

    always @(posedge clock) begin
        if (reset) begin
            sector_start <= 0; sector_lba <= 0;
            ready <= 0; busy <= 0; error <= 0; reading_boot <= 0;
            diagnostic_code <= 0;
            partition_lba <= 0; sectors_per_cluster <= 0;
            fat_lba <= 0; data_lba <= 0; root_cluster <= 0; root_lba <= 0;
            reserved_sectors <= 0; fat_count <= 0; fat_sectors <= 0;
            for (index = 0; index < 512; index = index + 1) buffer[index] <= 0;
        end else begin
            sector_start <= 0;
            if (sector_byte_valid) buffer[sector_offset] <= sector_byte;
            if (sector_error) begin busy <= 0; ready <= 0; error <= 1;
                diagnostic_code <= 0; end
            if (start && !busy) begin
                ready <= 0; error <= 0; diagnostic_code <= 0; busy <= 1; reading_boot <= 0;
                if (sector_ready) request_sector(0);
                else begin busy <= 0; error <= 1; end
            end
            if (sector_done && busy && !error) begin
                if (buffer[510] != 8'h55 || buffer[511] != 8'haa) begin
                    busy <= 0; error <= 1; diagnostic_code <= 1;
                end else if (!reading_boot) begin
                    // FAT32 superfloppy boot sectors have 512-byte sectors and
                    // a nonzero sectors-per-cluster field at the BPB offsets.
                    if (le16(11) == 512 && buffer[13] != 0) begin
                        partition_lba <= 0; reading_boot <= 1;
                        reserved_sectors <= le16(14); fat_count <= buffer[16];
                        fat_sectors <= le32(36); root_cluster <= le32(44);
                        sectors_per_cluster <= buffer[13];
                        fat_lba <= le16(14);
                        data_lba <= le16(14) + buffer[16] * le32(36);
                        root_lba <= le16(14) + buffer[16] * le32(36) +
                            (le32(44) - 2) * buffer[13];
                        busy <= 0; ready <= 1;
                    end else if ((buffer[450] == 8'h0b || buffer[450] == 8'h0c) &&
                                 le32(454) != 0 && sector_ready) begin
                        partition_lba <= le32(454); reading_boot <= 1;
                        request_sector(le32(454));
                    end else begin busy <= 0; error <= 1; diagnostic_code <= 2; end
                end else begin
                    if (le16(11) != 512 || buffer[13] == 0 ||
                        le16(14) == 0 || buffer[16] == 0 ||
                        le32(36) == 0 || le32(44) < 2) begin
                        busy <= 0; error <= 1; diagnostic_code <= 3;
                    end else begin
                        reserved_sectors <= le16(14); fat_count <= buffer[16];
                        fat_sectors <= le32(36); root_cluster <= le32(44);
                        sectors_per_cluster <= buffer[13];
                        fat_lba <= partition_lba + le16(14);
                        data_lba <= partition_lba + le16(14) +
                            buffer[16] * le32(36);
                        root_lba <= partition_lba + le16(14) +
                            buffer[16] * le32(36) + (le32(44) - 2) * buffer[13];
                        busy <= 0; ready <= 1;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
