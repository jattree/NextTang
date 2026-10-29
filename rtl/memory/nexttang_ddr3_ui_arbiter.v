// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Shares the Gowin DDR3 controller's user interface between two clients, one
// transaction at a time, as each client already uses it on its own.
//
// A client raises request while it waits to give a command. The arbiter grants
// one client, passes the controller's ready signals through to it alone, and
// keeps the grant until its write is accepted or its read's data returns, so
// returned data always belongs to the client that asked for it. When both are
// waiting the grant alternates, so neither waits behind more than one of the
// other's transactions.
module nexttang_ddr3_ui_arbiter (
    input  wire         clock,
    input  wire         reset,

    input  wire         a_request,
    output wire         a_command_ready,
    input  wire [2:0]   a_command,
    input  wire         a_command_enable,
    input  wire [28:0]  a_address,
    output wire         a_write_data_ready,
    input  wire [255:0] a_write_data,
    input  wire         a_write_data_enable,
    input  wire         a_write_data_end,
    input  wire [31:0]  a_write_data_mask,
    output wire         a_read_data_valid,
    input  wire         a_burst,

    input  wire         b_request,
    output wire         b_command_ready,
    input  wire [2:0]   b_command,
    input  wire         b_command_enable,
    input  wire [28:0]  b_address,
    output wire         b_write_data_ready,
    input  wire [255:0] b_write_data,
    input  wire         b_write_data_enable,
    input  wire         b_write_data_end,
    input  wire [31:0]  b_write_data_mask,
    output wire         b_read_data_valid,
    input  wire         b_burst,

    input  wire         controller_command_ready,
    output wire [2:0]   controller_command,
    output wire         controller_command_enable,
    output wire [28:0]  controller_address,
    input  wire         controller_write_data_ready,
    output wire [255:0] controller_write_data,
    output wire         controller_write_data_enable,
    output wire         controller_write_data_end,
    output wire [31:0]  controller_write_data_mask,
    input  wire         controller_read_data_valid,
    output wire         controller_burst
);
    reg granted;      // a client holds the interface
    reg grant_b;      // and it is B
    reg reading;      // its read was accepted and its data has not returned

    wire open_a = granted && !grant_b && !reading;
    wire open_b = granted && grant_b && !reading;

    assign a_command_ready = controller_command_ready && open_a;
    assign a_write_data_ready = controller_write_data_ready && open_a;
    assign a_read_data_valid = controller_read_data_valid && granted && !grant_b && reading;
    assign b_command_ready = controller_command_ready && open_b;
    assign b_write_data_ready = controller_write_data_ready && open_b;
    assign b_read_data_valid = controller_read_data_valid && granted && grant_b && reading;

    assign controller_command = grant_b ? b_command : a_command;
    assign controller_command_enable =
        open_a ? a_command_enable : open_b ? b_command_enable : 1'b0;
    assign controller_address = grant_b ? b_address : a_address;
    assign controller_write_data = grant_b ? b_write_data : a_write_data;
    assign controller_write_data_enable =
        open_a ? a_write_data_enable : open_b ? b_write_data_enable : 1'b0;
    assign controller_write_data_end = grant_b ? b_write_data_end : a_write_data_end;
    assign controller_write_data_mask = grant_b ? b_write_data_mask : a_write_data_mask;
    assign controller_burst = grant_b ? b_burst : a_burst;

    wire accepted = controller_command_enable && controller_command_ready;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            granted <= 1'b0;
            grant_b <= 1'b0;
            reading <= 1'b0;
        end else if (!granted) begin
            // B goes first only if A had the last grant or is not waiting.
            if (b_request && (grant_b == 1'b0 || !a_request)) begin
                granted <= 1'b1;
                grant_b <= 1'b1;
            end else if (a_request) begin
                granted <= 1'b1;
                grant_b <= 1'b0;
            end
        end else if (!reading) begin
            if (accepted) begin
                if (controller_command == 3'b001)
                    reading <= 1'b1;
                else
                    granted <= 1'b0;
            end
        end else if (controller_read_data_valid) begin
            reading <= 1'b0;
            granted <= 1'b0;
        end
    end
endmodule

`default_nettype wire
