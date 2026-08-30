// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Convert a FAT32 cluster chain into a contiguous read-only byte stream.
// byte_limit == 0 streams the complete chain (directory mode); otherwise the
// stream stops after exactly byte_limit bytes, while still allowing the SD
// transport to finish its current physical sector cleanly.
module nexttang_fat32_cluster_stream #(
    parameter integer MAX_CLUSTERS = 131072
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        start,
    input  wire        abort,
    input  wire        pause_requests,
    input  wire [31:0] first_cluster,
    input  wire [31:0] byte_limit,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_lba,
    input  wire [31:0] data_lba,
    output reg         sector_start,
    output reg  [31:0] sector_lba,
    input  wire        sector_ready,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_offset,
    input  wire        sector_byte_valid,
    input  wire        sector_done,
    input  wire        sector_error,
    output reg  [7:0]  stream_byte,
    output reg  [31:0] stream_offset,
    output reg         stream_valid,
    output reg         busy,
    output reg         done,
    output reg         error
);
    localparam [2:0] IDLE=0, DATA_REQUEST=1, DATA_WAIT=2,
                     FAT_REQUEST=3, FAT_WAIT=4, FINISH=5, FAILED=6;
    reg [2:0] state = IDLE;
    reg [31:0] cluster = 0;
    reg [7:0] cluster_sector = 0;
    reg [31:0] remaining = 0;
    reg limited = 0;
    reg [31:0] clusters_seen = 0;
    reg [31:0] fat_value = 0;
    reg abort_pending = 0;
    reg [31:0] position = 0;
    wire [8:0] fat_byte_offset = {cluster[6:0], 2'b00};
    wire [31:0] next_cluster = fat_value & 32'h0fffffff;

    always @(posedge clock) begin
        if (reset) begin
            state <= IDLE; sector_start <= 0; sector_lba <= 0;
            stream_byte <= 0; stream_offset <= 0; stream_valid <= 0;
            busy <= 0; done <= 0; error <= 0; cluster <= 0;
            cluster_sector <= 0; remaining <= 0; limited <= 0;
            clusters_seen <= 0; fat_value <= 0; abort_pending <= 0;
            position <= 0;
        end else begin
            sector_start <= 0; stream_valid <= 0; done <= 0;
            if (sector_error && busy) state <= FAILED;
            if (abort && busy) abort_pending <= 1;
            case (state)
                IDLE: if (start) begin
                    if (first_cluster < 2 || sectors_per_cluster == 0) begin
                        error <= 1; done <= 1;
                    end else begin
                        cluster <= first_cluster; cluster_sector <= 0;
                        remaining <= byte_limit; limited <= byte_limit != 0;
                        stream_offset <= 0; position <= 0; clusters_seen <= 1;
                        busy <= 1; error <= 0; abort_pending <= 0;
                        state <= DATA_REQUEST;
                    end
                end
                DATA_REQUEST: if (abort_pending || abort) begin
                    state <= FINISH;
                end else if (sector_ready && !pause_requests) begin
                    sector_lba <= data_lba + (cluster - 2) * sectors_per_cluster +
                                  cluster_sector;
                    sector_start <= 1; state <= DATA_WAIT;
                end
                DATA_WAIT: begin
                    if (sector_byte_valid && (!limited || remaining != 0)) begin
                        stream_byte <= sector_byte; stream_valid <= 1;
                        stream_offset <= position; position <= position + 1'b1;
                        if (limited) remaining <= remaining - 1'b1;
                    end
                    if (sector_done) begin
                        if (abort_pending || abort) begin
                            state <= FINISH;
                        end else if (limited && (remaining == 0 ||
                            (remaining == 1 && sector_byte_valid))) begin
                            state <= FINISH;
                        end else if (cluster_sector + 1 < sectors_per_cluster) begin
                            cluster_sector <= cluster_sector + 1'b1;
                            state <= DATA_REQUEST;
                        end else begin
                            fat_value <= 0; state <= FAT_REQUEST;
                        end
                    end
                end
                FAT_REQUEST: if (abort_pending || abort) begin
                    state <= FINISH;
                end else if (sector_ready) begin
                    sector_lba <= fat_lba + cluster[31:7];
                    sector_start <= 1; state <= FAT_WAIT;
                end
                FAT_WAIT: begin
                    if (sector_byte_valid && sector_offset >= fat_byte_offset &&
                        sector_offset < fat_byte_offset + 4)
                        fat_value[(sector_offset - fat_byte_offset) * 8 +: 8] <= sector_byte;
                    if (sector_done) begin
                        if (abort_pending || abort) state <= FINISH;
                        else if (next_cluster >= 32'h0ffffff8) state <= FINISH;
                        else if (next_cluster < 2 || next_cluster == 32'h0ffffff7 ||
                                 clusters_seen >= MAX_CLUSTERS) state <= FAILED;
                        else begin
                            cluster <= next_cluster; cluster_sector <= 0;
                            clusters_seen <= clusters_seen + 1'b1;
                            state <= DATA_REQUEST;
                        end
                    end
                end
                FINISH: begin busy <= 0; done <= 1; state <= IDLE; end
                FAILED: begin busy <= 0; error <= 1; done <= 1; state <= IDLE; end
                default: state <= FAILED;
            endcase
        end
    end
endmodule

`default_nettype wire
