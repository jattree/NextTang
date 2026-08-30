// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Mode-0 SPI byte engine. DIVIDER is the number of input clocks per half SCLK.
module nexttang_spi_byte_master #(
    parameter integer DIVIDER = 2,
    parameter integer FAST_DIVIDER = DIVIDER
) (
    input  wire       clock,
    input  wire       reset,
    input  wire       start,
    input  wire       fast,
    input  wire [7:0] transmit,
    output reg  [7:0] received,
    output reg        busy,
    output reg        done,
    output reg        sclk,
    output wire       mosi,
    input  wire       miso
);
    localparam integer COUNT_BITS = DIVIDER <= 2 ? 1 : $clog2(DIVIDER);
    reg [COUNT_BITS-1:0] divider_count = 0;
    reg [3:0] edge_count = 0;
    reg [7:0] shift_out = 8'hff;
    reg [7:0] shift_in = 0;
    wire [COUNT_BITS-1:0] active_divider =
        fast ? FAST_DIVIDER[COUNT_BITS-1:0] : DIVIDER[COUNT_BITS-1:0];

    assign mosi = shift_out[7];

    always @(posedge clock) begin
        if (reset) begin
            received <= 0; busy <= 0; done <= 0; sclk <= 0;
            divider_count <= 0; edge_count <= 0;
            shift_out <= 8'hff; shift_in <= 0;
        end else begin
            done <= 0;
            if (!busy) begin
                sclk <= 0;
                divider_count <= 0;
                if (start) begin
                    busy <= 1;
                    edge_count <= 0;
                    shift_out <= transmit;
                    shift_in <= 0;
                end
            end else if (divider_count == active_divider - 1'b1) begin
                divider_count <= 0;
                if (!sclk) begin
                    // Mode 0 samples MISO on each rising edge.
                    sclk <= 1;
                    shift_in <= {shift_in[6:0], miso};
                    edge_count <= edge_count + 1'b1;
                end else begin
                    sclk <= 0;
                    if (edge_count == 8) begin
                        busy <= 0;
                        done <= 1;
                        received <= shift_in;
                    end else begin
                        shift_out <= {shift_out[6:0], 1'b1};
                    end
                end
            end else begin
                divider_count <= divider_count + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
