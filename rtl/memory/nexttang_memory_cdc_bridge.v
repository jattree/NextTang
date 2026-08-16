// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// One-entry bundled-data mailbox for a request/response memory transaction.
// Request and response payloads remain stable until their toggle has crossed
// the two-flop synchroniser in the receiving clock domain.
// Both resets belong to one reset epoch and must assert together if an
// outstanding transaction is abandoned.
module nexttang_memory_cdc_bridge (
    input  wire        source_clock,
    input  wire        source_reset,
    input  wire        source_request,
    output wire        source_ready,
    input  wire        source_write,
    input  wire [20:0] source_address,
    input  wire [7:0]  source_write_data,
    output reg         source_response_valid,
    output reg  [7:0]  source_read_data,

    input  wire        destination_clock,
    input  wire        destination_reset,
    output reg         destination_request,
    input  wire        destination_ready,
    output reg         destination_write,
    output reg  [20:0] destination_address,
    output reg  [7:0]  destination_write_data,
    input  wire        destination_response_valid,
    input  wire [7:0]  destination_read_data
);
    localparam [1:0] DESTINATION_IDLE = 2'd0;
    localparam [1:0] DESTINATION_ISSUE = 2'd1;
    localparam [1:0] DESTINATION_RESPONSE = 2'd2;

    reg source_outstanding;
    reg request_toggle;
    reg request_write_hold;
    reg [20:0] request_address_hold;
    reg [7:0] request_write_data_hold;

    reg response_toggle;
    reg [7:0] response_read_data_hold;

    (* async_reg = "true" *) reg response_toggle_sync_1;
    (* async_reg = "true" *) reg response_toggle_sync_2;
    (* async_reg = "true" *) reg request_toggle_sync_1;
    (* async_reg = "true" *) reg request_toggle_sync_2;

    reg [1:0] destination_state;
    reg handled_request_toggle;
    reg active_request_toggle;

    assign source_ready = !source_outstanding;

    always @(posedge source_clock or posedge source_reset) begin
        if (source_reset) begin
            source_outstanding <= 1'b0;
            request_toggle <= 1'b0;
            request_write_hold <= 1'b0;
            request_address_hold <= 0;
            request_write_data_hold <= 0;
            response_toggle_sync_1 <= 1'b0;
            response_toggle_sync_2 <= 1'b0;
            source_response_valid <= 1'b0;
            source_read_data <= 0;
        end else begin
            response_toggle_sync_1 <= response_toggle;
            response_toggle_sync_2 <= response_toggle_sync_1;
            source_response_valid <= 1'b0;

            if (!source_outstanding && source_request) begin
                request_write_hold <= source_write;
                request_address_hold <= source_address;
                request_write_data_hold <= source_write_data;
                request_toggle <= ~request_toggle;
                source_outstanding <= 1'b1;
            end else if (source_outstanding &&
                         response_toggle_sync_2 == request_toggle) begin
                source_read_data <= response_read_data_hold;
                source_response_valid <= 1'b1;
                source_outstanding <= 1'b0;
            end
        end
    end

    always @(posedge destination_clock or posedge destination_reset) begin
        if (destination_reset) begin
            request_toggle_sync_1 <= 1'b0;
            request_toggle_sync_2 <= 1'b0;
            response_toggle <= 1'b0;
            response_read_data_hold <= 0;
            destination_state <= DESTINATION_IDLE;
            handled_request_toggle <= 1'b0;
            active_request_toggle <= 1'b0;
            destination_request <= 1'b0;
            destination_write <= 1'b0;
            destination_address <= 0;
            destination_write_data <= 0;
        end else begin
            request_toggle_sync_1 <= request_toggle;
            request_toggle_sync_2 <= request_toggle_sync_1;

            case (destination_state)
                DESTINATION_IDLE: begin
                    destination_request <= 1'b0;
                    if (request_toggle_sync_2 != handled_request_toggle) begin
                        destination_write <= request_write_hold;
                        destination_address <= request_address_hold;
                        destination_write_data <= request_write_data_hold;
                        destination_request <= 1'b1;
                        active_request_toggle <= request_toggle_sync_2;
                        destination_state <= DESTINATION_ISSUE;
                    end
                end

                DESTINATION_ISSUE: begin
                    if (destination_ready) begin
                        destination_request <= 1'b0;
                        if (destination_response_valid) begin
                            response_read_data_hold <= destination_read_data;
                            response_toggle <= active_request_toggle;
                            handled_request_toggle <= active_request_toggle;
                            destination_state <= DESTINATION_IDLE;
                        end else begin
                            destination_state <= DESTINATION_RESPONSE;
                        end
                    end
                end

                DESTINATION_RESPONSE: begin
                    if (destination_response_valid) begin
                        response_read_data_hold <= destination_read_data;
                        response_toggle <= active_request_toggle;
                        handled_request_toggle <= active_request_toggle;
                        destination_state <= DESTINATION_IDLE;
                    end
                end

                default: begin
                    destination_request <= 1'b0;
                    destination_state <= DESTINATION_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
