// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Read-only SD/SDHC SPI-mode initializer and 512-byte sector reader.
// A read request is accepted only when ready && !busy. Bytes are emitted in
// ascending offset order; no command capable of modifying the card is issued.
module nexttang_sd_spi_reader #(
    parameter integer CLOCK_HZ = 50_000_000,
    parameter integer INIT_SPI_HZ = 100_000,
    parameter integer DATA_SPI_HZ = 2_500_000,
    parameter integer RESPONSE_LIMIT = 1024,
    parameter integer INIT_RETRIES = 1024
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        read_start,
    input  wire [31:0] sector,
    output reg         ready,
    output reg         busy,
    output reg         error,
    output reg  [7:0]  byte_data,
    output reg  [8:0]  byte_offset,
    output reg         byte_valid,
    output reg         read_done,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output reg         sd_cs
);
    localparam integer INIT_DIVIDER_RAW = CLOCK_HZ / (2 * INIT_SPI_HZ);
    localparam integer INIT_DIVIDER = INIT_DIVIDER_RAW < 1 ? 1 : INIT_DIVIDER_RAW;
    localparam integer DATA_DIVIDER_RAW = CLOCK_HZ / (2 * DATA_SPI_HZ);
    localparam integer DATA_DIVIDER = DATA_DIVIDER_RAW < 1 ? 1 : DATA_DIVIDER_RAW;

    reg spi_start = 0;
    reg spi_fast = 0;
    reg [7:0] spi_tx = 8'hff;
    wire [7:0] spi_rx;
    wire spi_busy, spi_done;

    nexttang_spi_byte_master #(
        .DIVIDER(INIT_DIVIDER), .FAST_DIVIDER(DATA_DIVIDER)
    ) spi (
        .clock(clock), .reset(reset), .start(spi_start), .fast(spi_fast),
        .transmit(spi_tx),
        .received(spi_rx), .busy(spi_busy), .done(spi_done),
        .sclk(sd_clk), .mosi(sd_mosi), .miso(sd_miso)
    );

    localparam [5:0]
        ST_POWER_CLOCKS = 0, ST_POWER_WAIT = 1,
        ST_CMD_BEGIN = 2, ST_CMD_SEND = 3, ST_CMD_WAIT = 4,
        ST_RESPONSE_START = 5, ST_RESPONSE_WAIT = 6,
        ST_R7_START = 7, ST_R7_WAIT = 8,
        ST_IDLE_GAP = 9, ST_IDLE_GAP_WAIT = 10,
        ST_READY = 11, ST_TOKEN_START = 12, ST_TOKEN_WAIT = 13,
        ST_DATA_START = 14, ST_DATA_WAIT = 15,
        ST_CRC_START = 16, ST_CRC_WAIT = 17,
        ST_FINISH_GAP = 18, ST_FINISH_WAIT = 19,
        ST_ERROR = 20;

    localparam [2:0]
        OP_CMD0 = 0, OP_CMD8 = 1, OP_CMD55 = 2, OP_ACMD41 = 3,
        OP_CMD58 = 4, OP_CMD16 = 5, OP_CMD17 = 6;

    reg [5:0] state = ST_POWER_CLOCKS;
    reg [2:0] operation = OP_CMD0;
    reg [3:0] power_bytes = 0;
    reg [2:0] command_index = 0;
    reg [31:0] command_argument = 0;
    reg [7:0] command_crc = 8'h01;
    reg [15:0] response_count = 0;
    reg [2:0] extra_count = 0;
    reg [31:0] extra_response = 0;
    reg [15:0] retry_count = 0;
    reg card_v2 = 0;
    reg high_capacity = 0;
    reg [9:0] data_count = 0;
    reg crc_count = 0;

    function [7:0] command_byte;
        input [2:0] index_value;
        begin
            case (index_value)
                0: command_byte = 8'h40 | (operation == OP_CMD0 ? 0 :
                    operation == OP_CMD8 ? 8 : operation == OP_CMD55 ? 55 :
                    operation == OP_ACMD41 ? 41 : operation == OP_CMD58 ? 58 :
                    operation == OP_CMD16 ? 16 : 17);
                1: command_byte = command_argument[31:24];
                2: command_byte = command_argument[23:16];
                3: command_byte = command_argument[15:8];
                4: command_byte = command_argument[7:0];
                default: command_byte = command_crc;
            endcase
        end
    endfunction

    task begin_command;
        input [2:0] op;
        input [31:0] argument;
        input [7:0] crc;
        begin
            operation <= op; command_argument <= argument; command_crc <= crc;
            command_index <= 0; response_count <= 0;
            // Finish the previous command with at least eight clocks while
            // deselected.  Besides satisfying the SPI-mode Ncs gap, this lets
            // cards release MISO before the next command frame begins.
            sd_cs <= 1; state <= ST_IDLE_GAP;
        end
    endtask

    always @(posedge clock) begin
        if (reset) begin
            state <= ST_POWER_CLOCKS; operation <= OP_CMD0;
            spi_start <= 0; spi_fast <= 0; spi_tx <= 8'hff; sd_cs <= 1;
            ready <= 0; busy <= 1; error <= 0;
            byte_data <= 0; byte_offset <= 0; byte_valid <= 0; read_done <= 0;
            power_bytes <= 0; command_index <= 0; response_count <= 0;
            extra_count <= 0; extra_response <= 0; retry_count <= 0;
            card_v2 <= 0; high_capacity <= 0; data_count <= 0; crc_count <= 0;
        end else begin
            spi_start <= 0; byte_valid <= 0; read_done <= 0;
            case (state)
                ST_POWER_CLOCKS: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_POWER_WAIT;
                end
                ST_POWER_WAIT: if (spi_done) begin
                    if (power_bytes == 9) begin
                        power_bytes <= 0;
                        begin_command(OP_CMD0, 32'b0, 8'h95);
                    end else begin
                        power_bytes <= power_bytes + 1'b1;
                        state <= ST_POWER_CLOCKS;
                    end
                end
                ST_CMD_BEGIN: if (!spi_busy) begin
                    spi_tx <= command_byte(command_index);
                    spi_start <= 1; state <= ST_CMD_WAIT;
                end
                ST_CMD_WAIT: if (spi_done) begin
                    if (command_index == 5) state <= ST_RESPONSE_START;
                    else begin command_index <= command_index + 1'b1; state <= ST_CMD_BEGIN; end
                end
                ST_RESPONSE_START: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_RESPONSE_WAIT;
                end
                ST_RESPONSE_WAIT: if (spi_done) begin
                    if (!spi_rx[7]) begin
                        case (operation)
                            OP_CMD0: if (spi_rx == 8'h01) begin
                                retry_count <= 0;
                                begin_command(OP_CMD8, 32'h000001aa, 8'h87);
                            end else if (retry_count < INIT_RETRIES) begin
                                retry_count <= retry_count + 1'b1;
                                begin_command(OP_CMD0, 32'b0, 8'h95);
                            end else state <= ST_ERROR;
                            OP_CMD8: begin
                                card_v2 <= !(spi_rx & 8'h04);
                                if (spi_rx & 8'h04)
                                    begin_command(OP_CMD55, 0, 8'h01);
                                else begin extra_count <= 0; extra_response <= 0; state <= ST_R7_START; end
                            end
                            OP_CMD55: if (spi_rx <= 1)
                                begin_command(OP_ACMD41, card_v2 ? 32'h40000000 : 0, 8'h01);
                            else state <= ST_ERROR;
                            OP_ACMD41: if (spi_rx == 0)
                                begin_command(OP_CMD58, 0, 8'h01);
                            else if (spi_rx == 1 && retry_count < INIT_RETRIES) begin
                                retry_count <= retry_count + 1'b1;
                                begin_command(OP_CMD55, 0, 8'h01);
                            end else state <= ST_ERROR;
                            OP_CMD58: if (spi_rx == 0) begin
                                extra_count <= 0; extra_response <= 0; state <= ST_R7_START;
                            end else state <= ST_ERROR;
                            OP_CMD16: if (spi_rx == 0) begin
                                ready <= 1; busy <= 0; sd_cs <= 1; state <= ST_READY;
                            end else state <= ST_ERROR;
                            OP_CMD17: if (spi_rx == 0) begin
                                response_count <= 0; state <= ST_TOKEN_START;
                            end else state <= ST_ERROR;
                            default: state <= ST_ERROR;
                        endcase
                    end else if (response_count == RESPONSE_LIMIT - 1) begin
                        if (operation == OP_CMD0 && retry_count < INIT_RETRIES) begin
                            retry_count <= retry_count + 1'b1;
                            begin_command(OP_CMD0, 32'b0, 8'h95);
                        end else state <= ST_ERROR;
                    end
                    else begin response_count <= response_count + 1'b1; state <= ST_RESPONSE_START; end
                end
                ST_R7_START: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_R7_WAIT;
                end
                ST_R7_WAIT: if (spi_done) begin
                    extra_response <= {extra_response[23:0], spi_rx};
                    if (extra_count == 3) begin
                        if (operation == OP_CMD8) begin
                            if ({extra_response[3:0], spi_rx} != 12'h1aa)
                                state <= ST_ERROR;
                            else begin_command(OP_CMD55, 0, 8'h01);
                        end else begin
                            high_capacity <= extra_response[22];
                            spi_fast <= 1;
                            if (extra_response[22]) begin
                                ready <= 1; busy <= 0; sd_cs <= 1; state <= ST_READY;
                            end else begin_command(OP_CMD16, 32'd512, 8'h01);
                        end
                    end else begin extra_count <= extra_count + 1'b1; state <= ST_R7_START; end
                end
                ST_IDLE_GAP: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_IDLE_GAP_WAIT;
                end
                ST_IDLE_GAP_WAIT: if (spi_done) begin
                    sd_cs <= 0; state <= ST_CMD_BEGIN;
                end
                ST_READY: begin
                    sd_cs <= 1; ready <= 1; busy <= 0;
                    if (read_start) begin
                        ready <= 0; busy <= 1; data_count <= 0;
                        begin_command(OP_CMD17,
                            high_capacity ? sector : {sector[22:0], 9'b0}, 8'h01);
                    end
                end
                ST_TOKEN_START: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_TOKEN_WAIT;
                end
                ST_TOKEN_WAIT: if (spi_done) begin
                    if (spi_rx == 8'hfe) begin data_count <= 0; state <= ST_DATA_START; end
                    else if (spi_rx != 8'hff || response_count == RESPONSE_LIMIT - 1)
                        state <= ST_ERROR;
                    else begin response_count <= response_count + 1'b1; state <= ST_TOKEN_START; end
                end
                ST_DATA_START: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (spi_done) begin
                    byte_data <= spi_rx; byte_offset <= data_count[8:0]; byte_valid <= 1;
                    if (data_count == 511) begin crc_count <= 0; state <= ST_CRC_START; end
                    else begin data_count <= data_count + 1'b1; state <= ST_DATA_START; end
                end
                ST_CRC_START: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_CRC_WAIT;
                end
                ST_CRC_WAIT: if (spi_done) begin
                    if (crc_count) begin sd_cs <= 1; state <= ST_FINISH_GAP; end
                    else begin crc_count <= 1; state <= ST_CRC_START; end
                end
                ST_FINISH_GAP: if (!spi_busy) begin
                    spi_tx <= 8'hff; spi_start <= 1; state <= ST_FINISH_WAIT;
                end
                ST_FINISH_WAIT: if (spi_done) begin
                    read_done <= 1; ready <= 1; busy <= 0; state <= ST_READY;
                end
                default: begin
                    state <= ST_ERROR; ready <= 0; busy <= 0; error <= 1; sd_cs <= 1;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
