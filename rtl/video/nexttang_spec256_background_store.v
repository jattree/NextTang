// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// A Spec256 game's four backgrounds (B00 and BGX1's B01 to B03), each 256 x
// 192 palette indices, kept in DDR3, and copied one at a time into the
// overlay's background memory when the rules pick another. The overlay's
// block RAM holds one background; four do not fit beside the rest of the
// core.
//
// Machine side (clock): the loader's bytes for image load_image, address 0
// to 49151 in order, are packed 32 at a time and written as one DDR3 beat.
// copy_start reads image copy_image back and writes it out byte by byte on
// copy_write, address 0 up, about 2 ms for the whole picture; copy_busy is
// high until the last byte is out. A beat that completes while the one
// before is still on its way to DDR3 is dropped (lost), as is a copy_start
// during a copy.
//
// Memory side (memory_clock): one client of the DDR3 controller's user
// interface, as nexttang_ddr3_frame_store, through an arbiter. Image n beat
// b lives at beat BASE_BEAT + n * 2048 + b (32 bytes a beat).

`default_nettype none

module nexttang_spec256_background_store #(
    parameter integer BASE_BEAT = 'h20000
) (
    input  wire         clock,
    input  wire         reset,

    input  wire         load_write,
    input  wire [1:0]   load_image,
    input  wire [15:0]  load_address,
    input  wire [7:0]   load_data,
    output reg          lost,

    input  wire         copy_start,
    input  wire [1:0]   copy_image,
    output reg          copy_busy,
    output reg          copy_write,
    output reg  [15:0]  copy_address,
    output reg  [7:0]   copy_data,

    input  wire         memory_clock,
    input  wire         memory_reset,
    output wire         controller_request,
    input  wire         controller_command_ready,
    output wire [2:0]   controller_command,
    output wire         controller_command_enable,
    output wire [28:0]  controller_address,
    input  wire         controller_write_data_ready,
    output wire [255:0] controller_write_data,
    output wire         controller_write_data_enable,
    output wire         controller_write_data_end,
    output wire [31:0]  controller_write_data_mask,
    input  wire [255:0] controller_read_data,
    input  wire         controller_read_data_valid,
    output wire         controller_burst
);
    localparam integer BEATS = 1536;

    // Set on the memory side, read across.
    reg         memory_write_ack = 1'b0;
    reg         memory_read_request = 1'b0;

    // ------------------------------------------------------- machine side
    // Toggle handshakes: a request toggles, the other side toggles its
    // acknowledgement back; data stays put in between.
    reg [255:0] pack;
    reg [255:0] write_beat;          // to memory
    reg [12:0]  write_index;         // image, beat
    reg         write_request = 1'b0;
    reg [2:0]   write_ack_sync = 3'b000;
    wire        write_free = write_request == write_ack_sync[2];

    reg         copy_request = 1'b0;
    reg [1:0]   copy_which;
    reg [2:0]   read_request_sync = 3'b000;
    reg         read_ack = 1'b0;
    reg [255:0] read_beat;           // from memory, held by the memory side
    reg         unpacking;
    reg [4:0]   unpack_byte;
    reg [10:0]  beats_received;

    always @(posedge clock) begin
        write_ack_sync <= {write_ack_sync[1:0], memory_write_ack};
        read_request_sync <= {read_request_sync[1:0], memory_read_request};
        copy_write <= 1'b0;

        if (reset) begin
            lost <= 1'b0;
            copy_busy <= 1'b0;
            unpacking <= 1'b0;
        end else begin
            if (load_write) begin
                pack <= {load_data, pack[255:8]};
                if (load_address[4:0] == 5'd31) begin
                    if (write_free) begin
                        write_beat <= {load_data, pack[255:8]};
                        write_index <= {load_image, load_address[15:5]};
                        write_request <= !write_request;
                    end else begin
                        lost <= 1'b1;
                    end
                end
            end

            if (copy_start && !copy_busy) begin
                copy_busy <= 1'b1;
                copy_which <= copy_image;
                copy_request <= !copy_request;
                beats_received <= 11'd0;
            end

            // A beat from memory: 32 bytes out, then acknowledge.
            if (!unpacking && read_request_sync[2] != read_ack && copy_busy) begin
                unpacking <= 1'b1;
                unpack_byte <= 5'd0;
            end
            if (unpacking) begin
                copy_write <= 1'b1;
                copy_address <= {beats_received, unpack_byte};
                copy_data <= read_beat[8*unpack_byte +: 8];
                unpack_byte <= unpack_byte + 5'd1;
                if (unpack_byte == 5'd31) begin
                    unpacking <= 1'b0;
                    read_ack <= !read_ack;
                    beats_received <= beats_received + 11'd1;
                end
            end
            if (copy_busy && !unpacking && beats_received == BEATS)
                copy_busy <= 1'b0;
        end
    end

    // -------------------------------------------------------- memory side
    reg [2:0]   write_request_sync = 3'b000;
    reg [2:0]   copy_request_sync = 3'b000;
    reg [2:0]   read_ack_sync = 3'b000;

    localparam [2:0] IDLE = 3'd0;
    localparam [2:0] WRITE = 3'd1;
    localparam [2:0] READ_COMMAND = 3'd2;
    localparam [2:0] READ_DATA = 3'd3;
    localparam [2:0] HAND_OVER = 3'd4;

    reg [2:0]   state;
    reg [12:0]  beat_index;          // image, beat
    reg [255:0] held;
    reg [10:0]  beats_read;
    reg         copying;

    wire [25:0] beat_address = BASE_BEAT + {11'd0, beat_index[12:11], beat_index[10:0]};
    wire write_pair_ready = controller_command_ready && controller_write_data_ready;

    assign controller_request = state == WRITE || state == READ_COMMAND;
    assign controller_command = state == WRITE ? 3'b000 : 3'b001;
    assign controller_command_enable = (state == WRITE && write_pair_ready) ||
                                       state == READ_COMMAND;
    assign controller_address = {beat_address, 3'b000};
    assign controller_write_data = write_beat;
    assign controller_write_data_enable = state == WRITE && write_pair_ready;
    assign controller_write_data_end = 1'b1;
    assign controller_write_data_mask = 32'd0;
    assign controller_burst = 1'b0;

    always @(posedge memory_clock or posedge memory_reset) begin
        if (memory_reset) begin
            state <= IDLE;
            copying <= 1'b0;
            write_request_sync <= 3'b000;
            copy_request_sync <= 3'b000;
            read_ack_sync <= 3'b000;
            memory_write_ack <= 1'b0;
            memory_read_request <= 1'b0;
        end else begin
            write_request_sync <= {write_request_sync[1:0], write_request};
            copy_request_sync <= {copy_request_sync[1:0], copy_request};
            read_ack_sync <= {read_ack_sync[1:0], read_ack};

            case (state)
                IDLE: begin
                    if (write_request_sync[2] != memory_write_ack) begin
                        beat_index <= write_index;
                        state <= WRITE;
                    end else if (copy_request_sync[2] != copying) begin
                        copying <= !copying;
                        beat_index <= {copy_which, 11'd0};
                        beats_read <= 11'd0;
                        state <= READ_COMMAND;
                    end
                end

                WRITE: begin
                    if (write_pair_ready) begin
                        memory_write_ack <= !memory_write_ack;
                        state <= IDLE;
                    end
                end

                READ_COMMAND: begin
                    if (controller_command_ready)
                        state <= READ_DATA;
                end

                READ_DATA: begin
                    if (controller_read_data_valid) begin
                        held <= controller_read_data;
                        state <= HAND_OVER;
                    end
                end

                // The machine side takes the next beat once it has
                // acknowledged the last; meanwhile the next read goes out.
                HAND_OVER: begin
                    if (read_ack_sync[2] == memory_read_request) begin
                        read_beat <= held;
                        memory_read_request <= !memory_read_request;
                        beats_read <= beats_read + 11'd1;
                        beat_index[10:0] <= beat_index[10:0] + 11'd1;
                        state <= beats_read == BEATS - 1 ? IDLE : READ_COMMAND;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
