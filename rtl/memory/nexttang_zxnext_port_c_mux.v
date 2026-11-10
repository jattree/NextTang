// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Shares the board's main-memory path between the ZXNext core's port A (CPU
// and DMA) and port C (the official Pi debug slave, core 3.02.04 on).
//
// Port C goes through the same path as port A, ahead of the line cache and
// the Layer 2 mirror, so a debugger write updates every copy of the byte the
// way a CPU write does; no copy can go stale. Port A always wins: port C is
// served only while port A is idle, as the official boards give it the lowest
// priority, and port A's wait stays high while port C holds the path.
//
// Downstream, a request is a level held until wait falls (the memory port's
// contract). Between two owners the request drops for one cycle, so the
// memory port sees a new request rather than taking the second owner's access
// as already answered.
//
// Port C's own contract (official zxnext_top): the request is held until an
// acknowledge is seen, the acknowledge is a one-cycle pulse, and read data is
// valid from the cycle after it. The slave lowers its request the cycle after
// the acknowledge, so a request counts as new only once it has been seen low.
module nexttang_zxnext_port_c_mux (
    input  wire        clock,
    input  wire        reset,

    input  wire        a_request,
    input  wire        a_read_n,
    input  wire [20:0] a_address,
    input  wire [7:0]  a_write_data,
    output wire        a_wait,

    input  wire        c_request,
    input  wire        c_read_n,
    input  wire [20:0] c_address,
    input  wire [7:0]  c_write_data,
    output reg         c_ack,
    output reg  [7:0]  c_read_data,

    output wire        down_request,
    output wire        down_read_n,
    output wire [20:0] down_address,
    output wire [7:0]  down_write_data,
    input  wire        down_wait,
    input  wire [7:0]  down_read_data,

    output wire        c_busy
);
    localparam [1:0] PORT_A = 2'd0;
    localparam [1:0] PORT_C = 2'd1;
    localparam [1:0] GAP = 2'd2;

    reg [1:0]  owner = PORT_A;
    reg        c_seen_low = 1'b1;
    reg        c_held_read_n = 1'b0;
    reg [20:0] c_held_address = 21'd0;
    reg [7:0]  c_held_write_data = 8'd0;

    wire a_owns = owner == PORT_A;
    wire c_owns = owner == PORT_C;

    assign down_request = a_owns ? a_request : c_owns;
    assign down_read_n = a_owns ? a_read_n : c_held_read_n;
    assign down_address = a_owns ? a_address : c_held_address;
    assign down_write_data = a_owns ? a_write_data : c_held_write_data;
    assign a_wait = a_owns ? down_wait : a_request;
    assign c_busy = !a_owns || (c_request && c_seen_low);

    always @(posedge clock) begin
        c_ack <= 1'b0;
        if (!c_request)
            c_seen_low <= 1'b1;

        if (reset) begin
            owner <= PORT_A;
            c_seen_low <= 1'b1;
        end else begin
            case (owner)
                PORT_A:
                    if (!a_request && c_request && c_seen_low) begin
                        owner <= PORT_C;
                        c_seen_low <= 1'b0;
                        c_held_read_n <= c_read_n;
                        c_held_address <= c_address;
                        c_held_write_data <= c_write_data;
                    end
                PORT_C:
                    if (!down_wait) begin
                        c_read_data <= down_read_data;
                        c_ack <= 1'b1;
                        owner <= GAP;
                    end
                default:
                    owner <= PORT_A;
            endcase
        end
    end
endmodule

`default_nettype wire
