// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Decode a version-2 NextTang Spec256 game pack into the memories owned by a
// 48K Spec256 machine.  The CPUs remain held until the complete payload has
// passed its CRC32 check.  A fresh reset permits a failed or interrupted pack
// to be sent again.
//
// Version 2 appends between zero and eight 320x200 backgrounds.  Only the
// first is stored, because one is all the block RAM left on this device will
// hold; the rest are still clocked through the CRC so a truncated or corrupt
// pack is still refused.  The reference starts on background 0 as well.

`default_nettype none

module nexttang_spec256_game_loader (
    input  wire        clock,
    input  wire        reset,
    input  wire [7:0]  byte_data,
    input  wire        byte_valid,

    output reg         hold_reset,
    output reg         ready,
    output reg         fault,
    output reg  [20:0] received_bytes,

    output reg         boot_write_enable,
    output reg  [13:0] boot_write_address,
    output reg         main_write_enable,
    output reg  [15:0] main_write_address,
    output reg  [7:0]  graphics_ram_write_enable,
    output reg  [15:0] graphics_ram_write_address,
    output reg  [7:0]  graphics_rom_write_enable,
    output reg  [13:0] graphics_rom_write_address,
    output reg         palette_write_enable,
    output reg  [7:0]  palette_write_index,
    output reg  [23:0] palette_write_data,
    output reg         background_write_enable,
    output reg  [15:0] background_write_address,
    output reg         background_valid,
    output reg  [7:0]  write_data,

    output reg  [2:0]  launch_key_count,
    output reg  [7:0]  launch_key_0,
    output reg  [7:0]  launch_key_1,
    output reg  [7:0]  launch_key_2,
    output reg  [7:0]  launch_key_3,
    output reg  [15:0] launch_start_delay_ms,
    output reg  [15:0] launch_hold_ms,
    output reg  [15:0] launch_gap_ms
);
    localparam [1:0] STATE_HEADER  = 2'd0;
    localparam [1:0] STATE_PAYLOAD = 2'd1;
    localparam [1:0] STATE_DONE    = 2'd2;
    localparam [1:0] STATE_FAULT   = 2'd3;

    localparam integer HEADER_BYTES       = 32;
    localparam integer BOOT_BYTES         = 16384;
    localparam integer MAIN_BYTES         = 49152;
    localparam integer GRAPHICS_RAM_BYTES = 393216;
    localparam integer GRAPHICS_ROM_BYTES = 131072;
    localparam integer PALETTE_BYTES      = 768;
    localparam integer BACKGROUND_BYTES   = 64000;
    localparam integer MAX_BACKGROUNDS    = 8;
    localparam integer BASE_PAYLOAD_BYTES = BOOT_BYTES + MAIN_BYTES +
                                            GRAPHICS_RAM_BYTES +
                                            GRAPHICS_ROM_BYTES +
                                            PALETTE_BYTES;

    reg [1:0]  state;
    reg [5:0]  header_index;
    reg        header_bad;
    reg [15:0] header_version;
    reg [15:0] header_size;
    reg [31:0] header_payload_size;
    reg [31:0] expected_crc;
    reg [20:0] payload_index;
    reg [3:0]  background_count;
    reg [20:0] expected_payload_bytes;
    reg [31:0] running_crc;

    reg [2:0]  graphics_ram_lane;
    reg [15:0] graphics_ram_next_address;
    reg [2:0]  graphics_rom_lane;
    reg [13:0] graphics_rom_next_address;
    reg [1:0]  palette_byte;
    reg [7:0]  palette_next_index;
    reg [7:0]  palette_red;
    reg [7:0]  palette_green;

    function [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0] data;
        integer bit_index;
        reg [31:0] value;
        begin
            value = crc ^ data;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                if (value[0])
                    value = (value >> 1) ^ 32'hedb88320;
                else
                    value = value >> 1;
            crc32_byte = value;
        end
    endfunction

    always @(posedge clock) begin
        boot_write_enable <= 1'b0;
        main_write_enable <= 1'b0;
        graphics_ram_write_enable <= 8'b0;
        graphics_rom_write_enable <= 8'b0;
        palette_write_enable <= 1'b0;
        background_write_enable <= 1'b0;

        if (reset) begin
            state <= STATE_HEADER;
            header_index <= 0;
            header_bad <= 1'b0;
            header_version <= 0;
            background_count <= 0;
            background_valid <= 1'b0;
            expected_payload_bytes <= BASE_PAYLOAD_BYTES[20:0];
            header_size <= 0;
            header_payload_size <= 0;
            expected_crc <= 0;
            payload_index <= 0;
            running_crc <= 32'hffffffff;
            graphics_ram_lane <= 0;
            graphics_ram_next_address <= 16'h4000;
            graphics_rom_lane <= 0;
            graphics_rom_next_address <= 0;
            palette_byte <= 0;
            palette_next_index <= 0;
            palette_red <= 0;
            palette_green <= 0;
            hold_reset <= 1'b1;
            ready <= 1'b0;
            fault <= 1'b0;
            received_bytes <= 0;
            boot_write_address <= 0;
            main_write_address <= 0;
            graphics_ram_write_address <= 0;
            graphics_rom_write_address <= 0;
            palette_write_index <= 0;
            palette_write_data <= 0;
            write_data <= 0;
            launch_key_count <= 0;
            launch_key_0 <= 0;
            launch_key_1 <= 0;
            launch_key_2 <= 0;
            launch_key_3 <= 0;
            launch_start_delay_ms <= 0;
            launch_hold_ms <= 0;
            launch_gap_ms <= 0;
        end else if (byte_valid && state == STATE_HEADER) begin
            case (header_index)
                0: if (byte_data != "N") header_bad <= 1'b1;
                1: if (byte_data != "T") header_bad <= 1'b1;
                2: if (byte_data != "S") header_bad <= 1'b1;
                3: if (byte_data != "P") header_bad <= 1'b1;
                4: if (byte_data != "2") header_bad <= 1'b1;
                5: if (byte_data != "5") header_bad <= 1'b1;
                6: if (byte_data != "6") header_bad <= 1'b1;
                7: if (byte_data != 0)   header_bad <= 1'b1;
                8:  header_version[7:0] <= byte_data;
                9:  header_version[15:8] <= byte_data;
                10: header_size[7:0] <= byte_data;
                11: header_size[15:8] <= byte_data;
                12: header_payload_size[7:0] <= byte_data;
                13: header_payload_size[15:8] <= byte_data;
                14: header_payload_size[23:16] <= byte_data;
                15: header_payload_size[31:24] <= byte_data;
                16: expected_crc[7:0] <= byte_data;
                17: expected_crc[15:8] <= byte_data;
                18: expected_crc[23:16] <= byte_data;
                19: expected_crc[31:24] <= byte_data;
                20: begin
                    launch_key_count <= byte_data[2:0];
                    if (byte_data > 4)
                        header_bad <= 1'b1;
                end
                21: launch_key_0 <= byte_data;
                22: launch_key_1 <= byte_data;
                23: launch_key_2 <= byte_data;
                24: launch_key_3 <= byte_data;
                25: launch_start_delay_ms[7:0] <= byte_data;
                26: launch_start_delay_ms[15:8] <= byte_data;
                27: launch_hold_ms[7:0] <= byte_data;
                28: launch_hold_ms[15:8] <= byte_data;
                29: launch_gap_ms[7:0] <= byte_data;
                30: launch_gap_ms[15:8] <= byte_data;
                31: begin
                    background_count <= byte_data[3:0];
                    if (byte_data > MAX_BACKGROUNDS)
                        header_bad <= 1'b1;
                end
                default: ;
            endcase

            if (header_index == HEADER_BYTES - 1) begin
                if (header_bad || byte_data > MAX_BACKGROUNDS ||
                    header_version != 2 || header_size != HEADER_BYTES ||
                    header_payload_size != BASE_PAYLOAD_BYTES +
                                           byte_data * BACKGROUND_BYTES) begin
                    state <= STATE_FAULT;
                    fault <= 1'b1;
                end else begin
                    state <= STATE_PAYLOAD;
                    payload_index <= 0;
                    expected_payload_bytes <= BASE_PAYLOAD_BYTES[20:0] +
                                              byte_data * BACKGROUND_BYTES;
                    running_crc <= 32'hffffffff;
                end
            end else begin
                header_index <= header_index + 1'b1;
            end
        end else if (byte_valid && state == STATE_PAYLOAD) begin
            write_data <= byte_data;
            received_bytes <= payload_index + 1'b1;
            running_crc <= crc32_byte(running_crc, byte_data);

            if (payload_index < BOOT_BYTES) begin
                boot_write_enable <= 1'b1;
                boot_write_address <= payload_index[13:0];
            end else if (payload_index < BOOT_BYTES + MAIN_BYTES) begin
                main_write_enable <= 1'b1;
                main_write_address <= 16'h4000 +
                                      (payload_index - BOOT_BYTES);
            end else if (payload_index < BOOT_BYTES + MAIN_BYTES +
                                           GRAPHICS_RAM_BYTES) begin
                graphics_ram_write_enable <= 8'b1 << graphics_ram_lane;
                graphics_ram_write_address <= graphics_ram_next_address;
                if (graphics_ram_next_address == 16'hffff) begin
                    graphics_ram_next_address <= 16'h4000;
                    graphics_ram_lane <= graphics_ram_lane + 1'b1;
                end else begin
                    graphics_ram_next_address <=
                        graphics_ram_next_address + 1'b1;
                end
            end else if (payload_index < BOOT_BYTES + MAIN_BYTES +
                                           GRAPHICS_RAM_BYTES +
                                           GRAPHICS_ROM_BYTES) begin
                graphics_rom_write_enable <= 8'b1 << graphics_rom_lane;
                graphics_rom_write_address <= graphics_rom_next_address;
                if (graphics_rom_next_address == 14'h3fff) begin
                    graphics_rom_next_address <= 0;
                    graphics_rom_lane <= graphics_rom_lane + 1'b1;
                end else begin
                    graphics_rom_next_address <=
                        graphics_rom_next_address + 1'b1;
                end
            end else if (payload_index < BASE_PAYLOAD_BYTES +
                                           BACKGROUND_BYTES &&
                         payload_index >= BASE_PAYLOAD_BYTES) begin
                // Only background 0 is stored; later ones still clock through
                // the CRC so a short or corrupt pack is refused.
                background_write_enable <= 1'b1;
                background_write_address <=
                    payload_index[15:0] - BASE_PAYLOAD_BYTES[15:0];
            end else if (payload_index >= BASE_PAYLOAD_BYTES) begin
                // Backgrounds past the first are checked, not stored.
            end else begin
                case (palette_byte)
                    0: begin
                        palette_red <= byte_data;
                        palette_byte <= 1;
                    end
                    1: begin
                        palette_green <= byte_data;
                        palette_byte <= 2;
                    end
                    default: begin
                        palette_write_enable <= 1'b1;
                        palette_write_index <= palette_next_index;
                        palette_write_data <= {palette_red, palette_green,
                                               byte_data};
                        palette_byte <= 0;
                        palette_next_index <= palette_next_index + 1'b1;
                    end
                endcase
            end

            if (payload_index == expected_payload_bytes - 1'b1) begin
                if (~crc32_byte(running_crc, byte_data) == expected_crc) begin
                    state <= STATE_DONE;
                    ready <= 1'b1;
                    background_valid <= background_count != 0;
                    hold_reset <= 1'b0;
                end else begin
                    state <= STATE_FAULT;
                    fault <= 1'b1;
                end
            end else begin
                payload_index <= payload_index + 1'b1;
            end
        end else if (byte_valid &&
                     (state == STATE_DONE || state == STATE_FAULT) &&
                     byte_data == "N") begin
            // A fresh magic prefix is the runtime reset command.  Assert the
            // machine hold on its first byte, then overwrite every game-owned
            // memory before another CRC can release the CPUs.
            state <= STATE_HEADER;
            header_index <= 1;
            header_bad <= 1'b0;
            header_version <= 0;
            background_count <= 0;
            background_valid <= 1'b0;
            expected_payload_bytes <= BASE_PAYLOAD_BYTES[20:0];
            header_size <= 0;
            header_payload_size <= 0;
            expected_crc <= 0;
            payload_index <= 0;
            received_bytes <= 0;
            running_crc <= 32'hffffffff;
            graphics_ram_lane <= 0;
            graphics_ram_next_address <= 16'h4000;
            graphics_rom_lane <= 0;
            graphics_rom_next_address <= 0;
            palette_byte <= 0;
            palette_next_index <= 0;
            palette_red <= 0;
            palette_green <= 0;
            launch_key_count <= 0;
            launch_key_0 <= 0;
            launch_key_1 <= 0;
            launch_key_2 <= 0;
            launch_key_3 <= 0;
            launch_start_delay_ms <= 0;
            launch_hold_ms <= 0;
            launch_gap_ms <= 0;
            hold_reset <= 1'b1;
            ready <= 1'b0;
            fault <= 1'b0;
        end
    end
endmodule

`default_nettype wire
