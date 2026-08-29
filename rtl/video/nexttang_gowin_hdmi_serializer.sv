// SPDX-License-Identifier: MIT
// Gowin transport shim for the hdl-util HDMI transmitter.
module serializer #(
    parameter int NUM_CHANNELS = 3,
    parameter real VIDEO_RATE = 74.25E6
) (
    input  logic             clk_pixel,
    input  logic             clk_pixel_x5,
    input  logic             reset,
    input  logic [9:0]       tmds_internal [NUM_CHANNELS-1:0],
    output logic [2:0]       tmds,
    output logic             tmds_clock
);
    OSER10 channel_zero (
        .D0(tmds_internal[0][0]), .D1(tmds_internal[0][1]),
        .D2(tmds_internal[0][2]), .D3(tmds_internal[0][3]),
        .D4(tmds_internal[0][4]), .D5(tmds_internal[0][5]),
        .D6(tmds_internal[0][6]), .D7(tmds_internal[0][7]),
        .D8(tmds_internal[0][8]), .D9(tmds_internal[0][9]),
        .PCLK(clk_pixel), .FCLK(clk_pixel_x5),
        .RESET(reset), .Q(tmds[0])
    );

    OSER10 channel_one (
        .D0(tmds_internal[1][0]), .D1(tmds_internal[1][1]),
        .D2(tmds_internal[1][2]), .D3(tmds_internal[1][3]),
        .D4(tmds_internal[1][4]), .D5(tmds_internal[1][5]),
        .D6(tmds_internal[1][6]), .D7(tmds_internal[1][7]),
        .D8(tmds_internal[1][8]), .D9(tmds_internal[1][9]),
        .PCLK(clk_pixel), .FCLK(clk_pixel_x5),
        .RESET(reset), .Q(tmds[1])
    );

    OSER10 channel_two (
        .D0(tmds_internal[2][0]), .D1(tmds_internal[2][1]),
        .D2(tmds_internal[2][2]), .D3(tmds_internal[2][3]),
        .D4(tmds_internal[2][4]), .D5(tmds_internal[2][5]),
        .D6(tmds_internal[2][6]), .D7(tmds_internal[2][7]),
        .D8(tmds_internal[2][8]), .D9(tmds_internal[2][9]),
        .PCLK(clk_pixel), .FCLK(clk_pixel_x5),
        .RESET(reset), .Q(tmds[2])
    );

    assign tmds_clock = clk_pixel;

endmodule
