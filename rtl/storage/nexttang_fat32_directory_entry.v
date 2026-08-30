// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Stateful VFAT entry decoder. Feed consecutive 32-byte directory entries in
// on-disk order. Valid, checksum-matched LFN fragments are assembled across
// calls; otherwise an 8.3 fallback name is emitted.
module nexttang_fat32_directory_entry (
    input  wire         clock,
    input  wire         reset,
    input  wire         clear,
    input  wire         entry_start,
    input  wire [255:0] entry_data,
    output reg          busy,
    output reg          entry_done,
    output reg          file_valid,
    output reg          end_directory,
    output reg  [7:0]   attributes,
    output reg  [31:0]  first_cluster,
    output reg  [31:0]  file_size,
    output reg  [7:0]   name_length,
    input  wire [7:0]   name_index,
    output wire [7:0]   name_data
);
    // This small, asynchronously-read LFN scratchpad is intentionally LUT RAM.
    // Keeping it out of BSRAM lets the shared loader coexist with the
    // BSRAM-saturated Spec256 machine without changing any machine memory.
    (* syn_ramstyle = "distributed_ram" *) reg [7:0] name [0:254];
    reg [255:0] current_entry;
    reg [4:0] lfn_ordinal = 0;
    reg [3:0] character_index = 0;
    reg [7:0] lfn_checksum = 0;
    reg lfn_active = 0;
    reg lfn_terminated = 0;
    reg [3:0] short_index = 0;
    reg [7:0] short_length = 0;
    reg extension_dot = 0;
    reg extension_exists = 0;
    reg [255:0] short_shift = 0;
    reg [207:0] lfn_characters = 0;
    reg [8:0] lfn_position = 0;
    wire [15:0] lfn_character = lfn_characters[15:0];
    wire [4:0] incoming_ordinal = byte_at(entry_data,0) & 8'h1f;
    wire [8:0] incoming_position = (incoming_ordinal - 1'b1) * 4'd13;
    reg [1:0] state = 0;
    integer index;

    assign name_data = name[name_index];

    function [7:0] byte_at;
        input [255:0] value;
        input integer offset;
        begin byte_at = value[offset * 8 +: 8]; end
    endfunction
    function [5:0] lfn_low_offset;
        input [3:0] slot;
        begin
            case (slot)
                0: lfn_low_offset=1; 1: lfn_low_offset=3; 2: lfn_low_offset=5;
                3: lfn_low_offset=7; 4: lfn_low_offset=9; 5: lfn_low_offset=14;
                6: lfn_low_offset=16; 7: lfn_low_offset=18; 8: lfn_low_offset=20;
                9: lfn_low_offset=22; 10: lfn_low_offset=24;
                11: lfn_low_offset=28; default: lfn_low_offset=30;
            endcase
        end
    endfunction
    function [7:0] short_checksum;
        input [255:0] value;
        integer number;
        reg [7:0] sum;
        begin
            sum = 0;
            for (number = 0; number < 11; number = number + 1)
                sum = {sum[0], sum[7:1]} + byte_at(value, number);
            short_checksum = sum;
        end
    endfunction

    always @(posedge clock) begin
        if (reset) begin
            busy <= 0; entry_done <= 0; file_valid <= 0; end_directory <= 0;
            attributes <= 0; first_cluster <= 0; file_size <= 0;
            name_length <= 0; current_entry <= 0; lfn_ordinal <= 0;
            character_index <= 0; lfn_checksum <= 0; lfn_active <= 0;
            lfn_terminated <= 0; short_index <= 0; short_length <= 0;
            extension_dot <= 0; extension_exists <= 0; short_shift <= 0;
            lfn_characters <= 0; lfn_position <= 0; state <= 0;
            for (index = 0; index < 255; index = index + 1) name[index] <= 0;
        end else begin
            entry_done <= 0; file_valid <= 0;
            if (clear && !busy) begin
                end_directory <= 0; lfn_active <= 0; lfn_terminated <= 0;
                name_length <= 0;
            end else if (entry_start && !busy && !end_directory) begin
                current_entry <= entry_data; busy <= 1;
                if (byte_at(entry_data, 0) == 0) begin
                    end_directory <= 1; busy <= 0; entry_done <= 1;
                    lfn_active <= 0;
                end else if (byte_at(entry_data, 0) == 8'he5) begin
                    busy <= 0; entry_done <= 1; lfn_active <= 0;
                end else if (byte_at(entry_data, 11) == 8'h0f &&
                             incoming_ordinal != 0 && incoming_ordinal <= 20) begin
                    lfn_ordinal <= incoming_ordinal;
                    character_index <= 0; state <= 1;
                    lfn_position <= incoming_position;
                    lfn_characters[15:0] <= {byte_at(entry_data,2),byte_at(entry_data,1)};
                    lfn_characters[31:16] <= {byte_at(entry_data,4),byte_at(entry_data,3)};
                    lfn_characters[47:32] <= {byte_at(entry_data,6),byte_at(entry_data,5)};
                    lfn_characters[63:48] <= {byte_at(entry_data,8),byte_at(entry_data,7)};
                    lfn_characters[79:64] <= {byte_at(entry_data,10),byte_at(entry_data,9)};
                    lfn_characters[95:80] <= {byte_at(entry_data,15),byte_at(entry_data,14)};
                    lfn_characters[111:96] <= {byte_at(entry_data,17),byte_at(entry_data,16)};
                    lfn_characters[127:112] <= {byte_at(entry_data,19),byte_at(entry_data,18)};
                    lfn_characters[143:128] <= {byte_at(entry_data,21),byte_at(entry_data,20)};
                    lfn_characters[159:144] <= {byte_at(entry_data,23),byte_at(entry_data,22)};
                    lfn_characters[175:160] <= {byte_at(entry_data,25),byte_at(entry_data,24)};
                    lfn_characters[191:176] <= {byte_at(entry_data,29),byte_at(entry_data,28)};
                    lfn_characters[207:192] <= {byte_at(entry_data,31),byte_at(entry_data,30)};
                    if (byte_at(entry_data, 0) & 8'h40) begin
                        lfn_active <= 1; lfn_checksum <= byte_at(entry_data, 13);
                        lfn_terminated <= 0; name_length <= 0;
                    end else if (!lfn_active || lfn_checksum != byte_at(entry_data, 13)) begin
                        lfn_active <= 0;
                    end
                end else if (byte_at(entry_data, 11) & 8'h08) begin
                    // Ignore volume labels, and never let their preceding bytes
                    // leak into the following real entry.
                    busy <= 0; entry_done <= 1; lfn_active <= 0;
                end else begin
                    attributes <= byte_at(entry_data, 11);
                    first_cluster <= {byte_at(entry_data, 21), byte_at(entry_data, 20),
                                      byte_at(entry_data, 27), byte_at(entry_data, 26)};
                    file_size <= {byte_at(entry_data, 31), byte_at(entry_data, 30),
                                  byte_at(entry_data, 29), byte_at(entry_data, 28)};
                    if (lfn_active && lfn_checksum == short_checksum(entry_data)) begin
                        busy <= 0; entry_done <= 1; file_valid <= 1;
                        lfn_active <= 0;
                    end else begin
                        lfn_active <= 0; short_index <= 0; short_length <= 0;
                        extension_dot <= 0; name_length <= 0;
                        extension_exists <= byte_at(entry_data,8)!=8'h20 ||
                            byte_at(entry_data,9)!=8'h20 || byte_at(entry_data,10)!=8'h20;
                        short_shift <= entry_data; state <= 2;
                    end
                end
            end else if (busy && state == 1) begin
                if (!lfn_active || byte_at(current_entry, 13) != lfn_checksum) begin
                    busy <= 0; entry_done <= 1; lfn_active <= 0; state <= 0;
                end else begin
                    if (lfn_character == 16'h0000) begin
                        if (!lfn_terminated) begin
                            name_length <= lfn_position[7:0];
                            lfn_terminated <= 1;
                        end
                    end else if (lfn_character != 16'hffff &&
                                 lfn_position < 255 &&
                                 (!lfn_terminated || lfn_position < name_length)) begin
                        name[lfn_position[7:0]] <= lfn_character[15:8] == 0 ?
                            lfn_character[7:0] : 8'h3f;
                        if (!lfn_terminated &&
                            lfn_position + 1'b1 > name_length)
                            name_length <= lfn_position[7:0] + 1'b1;
                    end
                    lfn_characters <= {16'hffff,lfn_characters[207:16]};
                    lfn_position <= lfn_position + 1'b1;
                    if (character_index == 12) begin
                        busy <= 0; entry_done <= 1; state <= 0;
                    end else character_index <= character_index + 1'b1;
                end
            end else if (busy && state == 2) begin
                if (short_index == 8 && !extension_dot && extension_exists) begin
                    name[short_length] <= 8'h2e; short_length <= short_length + 1'b1;
                    extension_dot <= 1;
                end else begin
                    if (short_shift[7:0] != 8'h20) begin
                        name[short_length] <= short_shift[7:0];
                        short_length <= short_length + 1'b1;
                    end
                    short_shift <= {8'h20,short_shift[255:8]};
                    if (short_index == 10) begin
                        name_length <= short_length +
                            (short_shift[7:0] != 8'h20);
                        busy <= 0; entry_done <= 1; file_valid <= 1; state <= 0;
                    end else short_index <= short_index + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
