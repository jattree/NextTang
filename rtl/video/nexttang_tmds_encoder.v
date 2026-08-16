// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

module nexttang_tmds_encoder (
    input  wire       pixel_clk,
    input  wire       reset,
    input  wire [7:0] video_data,
    input  wire       control_zero,
    input  wire       control_one,
    input  wire       data_enable,
    output reg  [9:0] symbol
);
    reg [8:0] transition_minimised;
    reg use_xnor;
    reg [3:0] input_ones;
    reg [3:0] encoded_ones;
    reg signed [5:0] balance;
    reg signed [5:0] disparity;
    integer index;

    always @* begin
        input_ones = video_data[0] + video_data[1] + video_data[2] +
                     video_data[3] + video_data[4] + video_data[5] +
                     video_data[6] + video_data[7];
        use_xnor = input_ones > 4 || (input_ones == 4 && !video_data[0]);
        transition_minimised[0] = video_data[0];
        for (index = 1; index < 8; index = index + 1) begin
            if (use_xnor)
                transition_minimised[index] =
                    ~(transition_minimised[index - 1] ^ video_data[index]);
            else
                transition_minimised[index] =
                    transition_minimised[index - 1] ^ video_data[index];
        end
        transition_minimised[8] = !use_xnor;

        encoded_ones = transition_minimised[0] + transition_minimised[1] +
                       transition_minimised[2] + transition_minimised[3] +
                       transition_minimised[4] + transition_minimised[5] +
                       transition_minimised[6] + transition_minimised[7];
        balance = $signed({1'b0, encoded_ones, 1'b0}) - 6'sd8;
    end

    always @(posedge pixel_clk) begin
        if (reset) begin
            symbol <= 10'b1101010100;
            disparity <= 0;
        end else if (!data_enable) begin
            disparity <= 0;
            case ({control_one, control_zero})
                2'b00: symbol <= 10'b1101010100;
                2'b01: symbol <= 10'b0010101011;
                2'b10: symbol <= 10'b0101010100;
                default: symbol <= 10'b1010101011;
            endcase
        end else if (disparity == 0 || balance == 0) begin
            symbol[9] <= !transition_minimised[8];
            symbol[8] <= transition_minimised[8];
            if (transition_minimised[8]) begin
                symbol[7:0] <= transition_minimised[7:0];
                disparity <= $signed(disparity) + $signed(balance);
            end else begin
                symbol[7:0] <= ~transition_minimised[7:0];
                disparity <= $signed(disparity) - $signed(balance);
            end
        end else if ((disparity > 0 && balance > 0) ||
                     (disparity < 0 && balance < 0)) begin
            symbol <= {1'b1, transition_minimised[8],
                       ~transition_minimised[7:0]};
            disparity <= $signed(disparity) - $signed(balance) +
                         (transition_minimised[8] ? 6'sd2 : 6'sd0);
        end else begin
            symbol <= {1'b0, transition_minimised[8],
                       transition_minimised[7:0]};
            disparity <= $signed(disparity) + $signed(balance) -
                         (transition_minimised[8] ? 6'sd0 : 6'sd2);
        end
    end
endmodule

`default_nettype wire
