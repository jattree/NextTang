// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Adapt explicit 16-byte lines to the 32-byte controller beats used by the
// exact C-silicon Tang Console 138K DDR3 configuration. Two machine lines
// share each controller beat; byte masks protect the untouched half.
//
// The controller accepts a write before a following read can see it, so by
// default each write is held for WRITE_DRAIN_CYCLES before it completes. With
// POSTED_WRITES set, a write completes as soon as the controller accepts it
// instead, and the adapter remembers it for the same WRITE_DRAIN_CYCLES: the
// line, its data and its byte enables, one entry per line, with later writes to
// a pending line merged into its entry. A read is issued at once and its
// result is patched with the pending entry for its line, taken when the read
// is issued, so it never returns data older than the latest write. Only when
// all PENDING_LINES entries are in use does a request wait, for the oldest to
// expire. A posted request spends two extra cycles, one to find its line in
// the table and one to update it, which keeps the 128-bit merge out of the
// cycle that receives the request.
module nexttang_gowin_ddr3_ui_adapter #(
    parameter integer WRITE_DRAIN_CYCLES = 1024,
    parameter integer POSTED_WRITES = 0,
    parameter integer PENDING_LINES = 8
) (
    input  wire         clock,
    input  wire         reset,

    input  wire         line_request,
    output wire         line_ready,
    input  wire         line_write,
    input  wire [16:0]  line_address,
    input  wire [127:0] line_write_data,
    input  wire [15:0]  line_write_enable,
    output reg          line_response_valid,
    output reg  [127:0] line_read_data,

    // Waiting to give the controller a command, for an arbiter that shares it.
    output wire         controller_request,
    input  wire         controller_command_ready,
    output reg  [2:0]   controller_command,
    output wire         controller_command_enable,
    output reg  [28:0]  controller_address,
    input  wire         controller_write_data_ready,
    output reg  [255:0] controller_write_data,
    output wire         controller_write_data_enable,
    output wire         controller_write_data_end,
    output reg  [31:0]  controller_write_data_mask,
    input  wire [255:0] controller_read_data,
    input  wire         controller_read_data_valid,
    output wire         controller_burst
);
    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_WRITE = 3'd1;
    localparam [2:0] STATE_WRITE_DRAIN = 3'd2;
    localparam [2:0] STATE_READ_COMMAND = 3'd3;
    localparam [2:0] STATE_READ_RESPONSE = 3'd4;
    localparam [2:0] STATE_LOOKUP = 3'd5;
    localparam [2:0] STATE_UPDATE = 3'd6;

    reg [2:0] state;
    reg [31:0] write_drain_counter;
    reg read_upper_half;

    wire write_pair_ready = controller_command_ready &&
                            controller_write_data_ready;

    // ------------------------------------------------ posted write tracking
    localparam integer ENTRY_BITS = PENDING_LINES > 1 ? $clog2(PENDING_LINES) : 1;

    // The table is searched in parallel every cycle, so it stays in
    // registers. Left to infer RAM, GowinSynthesis 1.9.12.03 crashes with a
    // floating-point exception during inference.
    (* syn_ramstyle = "registers" *) reg          pending_valid [0:PENDING_LINES-1];
    (* syn_ramstyle = "registers" *) reg          pending_accepted [0:PENDING_LINES-1];
    (* syn_ramstyle = "registers" *) reg [16:0]   pending_line [0:PENDING_LINES-1];
    (* syn_ramstyle = "registers" *) reg [127:0]  pending_data [0:PENDING_LINES-1];
    (* syn_ramstyle = "registers" *) reg [15:0]   pending_enable [0:PENDING_LINES-1];
    (* syn_ramstyle = "registers" *) reg [31:0]   pending_timer [0:PENDING_LINES-1];
    reg [ENTRY_BITS-1:0] write_entry;
    reg [127:0]          read_patch_data;
    reg [15:0]           read_patch_enable;
    reg [16:0]           request_line;
    reg [127:0]          request_data;
    reg [15:0]           request_enable;
    reg                  request_write;
    reg                  lookup_match;
    reg [ENTRY_BITS-1:0] lookup_entry;

    // The entry already holding a line, and a free entry for a new one.
    reg                  match_found;
    reg [ENTRY_BITS-1:0] match_entry;
    reg                  free_found;
    reg [ENTRY_BITS-1:0] free_entry;
    integer search;

    always @(*) begin
        match_found = 1'b0;
        match_entry = 0;
        free_found = 1'b0;
        free_entry = 0;
        for (search = PENDING_LINES - 1; search >= 0; search = search - 1) begin
            if (pending_valid[search] && pending_line[search] == request_line) begin
                match_found = 1'b1;
                match_entry = search;
            end
            if (!pending_valid[search]) begin
                free_found = 1'b1;
                free_entry = search;
            end
        end
    end

    function [127:0] merge_bytes(input [127:0] older, input [127:0] newer, input [15:0] enable);
        integer index;
        begin
            for (index = 0; index < 16; index = index + 1)
                merge_bytes[index*8 +: 8] = enable[index] ? newer[index*8 +: 8] : older[index*8 +: 8];
        end
    endfunction

    wire table_has_room = POSTED_WRITES == 0 || free_found;

    assign line_ready = state == STATE_IDLE && table_has_room;
    assign controller_request = state == STATE_WRITE || state == STATE_READ_COMMAND;
    // The exact-C controller only passed hardware readback when command and
    // write data were presented as one paired transaction. Do not let either
    // channel be accepted alone even though the public interface exposes
    // separate ready signals.
    assign controller_command_enable =
        (state == STATE_WRITE && write_pair_ready) ||
        state == STATE_READ_COMMAND;
    assign controller_write_data_enable =
        state == STATE_WRITE && write_pair_ready;
    assign controller_write_data_end = 1'b1;
    assign controller_burst = 1'b0;

    integer entry;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            for (entry = 0; entry < PENDING_LINES; entry = entry + 1) begin
                pending_valid[entry] <= 1'b0;
                pending_accepted[entry] <= 1'b0;
                pending_line[entry] <= 0;
                pending_data[entry] <= 0;
                pending_enable[entry] <= 0;
                pending_timer[entry] <= 0;
            end
            write_entry <= 0;
            read_patch_data <= 0;
            read_patch_enable <= 0;
        end else if (POSTED_WRITES != 0) begin
            // An accepted write is remembered until the controller has had
            // WRITE_DRAIN_CYCLES to make it visible.
            for (entry = 0; entry < PENDING_LINES; entry = entry + 1) begin
                if (pending_valid[entry] && pending_accepted[entry]) begin
                    if (pending_timer[entry] <= 1)
                        pending_valid[entry] <= 1'b0;
                    else
                        pending_timer[entry] <= pending_timer[entry] - 1;
                end
            end

            if (state == STATE_IDLE && line_request && line_ready) begin
                request_line <= line_address;
                request_data <= line_write_data;
                request_enable <= line_write_enable;
                request_write <= line_write;
            end

            if (state == STATE_LOOKUP) begin
                lookup_match <= match_found;
                lookup_entry <= match_found ? match_entry : free_entry;
            end

            if (state == STATE_UPDATE) begin
                if (request_write) begin
                    if (lookup_match) begin
                        pending_data[lookup_entry] <= merge_bytes(
                            pending_data[lookup_entry], request_data, request_enable);
                        pending_enable[lookup_entry] <= pending_enable[lookup_entry] | request_enable;
                    end else begin
                        pending_line[lookup_entry] <= request_line;
                        pending_data[lookup_entry] <= request_data;
                        pending_enable[lookup_entry] <= request_enable;
                    end
                    // The entry may be expiring on this very edge; the write
                    // keeps it.
                    pending_valid[lookup_entry] <= 1'b1;
                    pending_accepted[lookup_entry] <= 1'b0;
                    pending_timer[lookup_entry] <= WRITE_DRAIN_CYCLES;
                    write_entry <= lookup_entry;
                end else begin
                    // Whatever is pending for this line when the read goes
                    // out is newer than anything the read can return.
                    read_patch_data <= lookup_match ? pending_data[lookup_entry] : 128'b0;
                    read_patch_enable <= lookup_match ? pending_enable[lookup_entry] : 16'b0;
                end
            end

            if (state == STATE_WRITE && write_pair_ready)
                pending_accepted[write_entry] <= 1'b1;
        end
    end

    // The read data as returned, with the pending write's bytes laid over it.
    wire [127:0] returned_line = read_upper_half
        ? controller_read_data[255:128]
        : controller_read_data[127:0];
    wire [127:0] patched_line = POSTED_WRITES != 0
        ? merge_bytes(returned_line, read_patch_data, read_patch_enable)
        : returned_line;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            state <= STATE_IDLE;
            write_drain_counter <= 0;
            read_upper_half <= 1'b0;
            line_response_valid <= 1'b0;
            line_read_data <= 0;
            controller_command <= 0;
            controller_address <= 0;
            controller_write_data <= 0;
            controller_write_data_mask <= {32{1'b1}};
        end else begin
            line_response_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    write_drain_counter <= 0;

                    if (line_request && line_ready) begin
                        controller_address <= {
                            10'b0, line_address[16:1], 3'b0
                        };
                        read_upper_half <= line_address[0];
                        if (line_write) begin
                            controller_command <= 3'b000;
                            controller_write_data <= line_address[0]
                                ? {line_write_data, 128'b0}
                                : {128'b0, line_write_data};
                            controller_write_data_mask <= line_address[0]
                                ? {~line_write_enable, 16'hffff}
                                : {16'hffff, ~line_write_enable};
                            state <= POSTED_WRITES != 0 ? STATE_LOOKUP : STATE_WRITE;
                        end else begin
                            controller_command <= 3'b001;
                            state <= POSTED_WRITES != 0 ? STATE_LOOKUP : STATE_READ_COMMAND;
                        end
                    end
                end

                STATE_LOOKUP: begin
                    state <= STATE_UPDATE;
                end

                STATE_UPDATE: begin
                    state <= controller_command == 3'b000 ? STATE_WRITE : STATE_READ_COMMAND;
                end

                STATE_WRITE: begin
                    if (write_pair_ready) begin
                        write_drain_counter <= 0;
                        if (POSTED_WRITES != 0) begin
                            line_response_valid <= 1'b1;
                            state <= STATE_IDLE;
                        end else begin
                            state <= STATE_WRITE_DRAIN;
                        end
                    end
                end

                STATE_WRITE_DRAIN: begin
                    // Acceptance only queues the write inside the vendor
                    // controller. The hardware-proven boundary waits before
                    // allowing a dependent CPU transaction to follow it.
                    if (WRITE_DRAIN_CYCLES == 0 ||
                        write_drain_counter + 1 >= WRITE_DRAIN_CYCLES) begin
                        line_response_valid <= 1'b1;
                        state <= STATE_IDLE;
                    end else begin
                        write_drain_counter <= write_drain_counter + 1'b1;
                    end
                end

                STATE_READ_COMMAND: begin
                    if (controller_command_ready) begin
                        if (controller_read_data_valid) begin
                            line_read_data <= patched_line;
                            line_response_valid <= 1'b1;
                            state <= STATE_IDLE;
                        end else begin
                            state <= STATE_READ_RESPONSE;
                        end
                    end
                end

                STATE_READ_RESPONSE: begin
                    if (controller_read_data_valid) begin
                        line_read_data <= patched_line;
                        line_response_valid <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
