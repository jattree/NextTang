// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_logo_framebuffer (
    input  wire        write_clock,
    input  wire        write_enable,
    input  wire        write_bank,
    input  wire [8:0]  write_address,
    input  wire [255:0] write_data,
    input  wire        read_clock,
    input  wire        read_bank,
    input  wire [13:0] read_address,
    output wire [7:0]  read_data
);
    wire [7:0] bank_zero_read_data [0:31];
    wire [7:0] bank_one_read_data [0:31];

    genvar lane;
    generate
        for (lane = 0; lane < 32; lane = lane + 1) begin : framebuffer_lane
            reg [7:0] bank_zero [0:511];
            reg [7:0] bank_one [0:511];
            reg [7:0] zero_read_data;
            reg [7:0] one_read_data;

            always @(posedge write_clock) begin
                if (write_enable && !write_bank)
                    bank_zero[write_address] <= write_data[lane * 8 +: 8];
                if (write_enable && write_bank)
                    bank_one[write_address] <= write_data[lane * 8 +: 8];
            end

            always @(posedge read_clock) begin
                zero_read_data <= bank_zero[read_address[13:5]];
                one_read_data <= bank_one[read_address[13:5]];
            end

            assign bank_zero_read_data[lane] = zero_read_data;
            assign bank_one_read_data[lane] = one_read_data;
        end
    endgenerate

    assign read_data = read_bank
        ? bank_one_read_data[read_address[4:0]]
        : bank_zero_read_data[read_address[4:0]];
endmodule

`default_nettype wire
