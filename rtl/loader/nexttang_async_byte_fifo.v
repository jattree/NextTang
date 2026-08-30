// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// 1024-byte dual-clock FIFO with Gray-coded pointer crossing.
module nexttang_async_byte_fifo (
    input  wire       write_clock,
    input  wire       write_reset,
    input  wire       write_clear,
    input  wire [7:0] write_data,
    input  wire       write_enable,
    output wire       write_full,
    output wire [10:0] write_level,
    input  wire       read_clock,
    input  wire       read_reset,
    input  wire       read_clear,
    output reg  [7:0] read_data,
    output reg        read_valid,
    input  wire       read_pop
);
    reg [7:0] memory [0:1023];
    reg [10:0] write_binary=0,write_gray=0,read_binary=0,read_gray=0;
    reg [10:0] read_gray_w1=0,read_gray_w2=0,write_gray_r1=0,write_gray_r2=0;
    wire [10:0] write_binary_next=write_binary+1'b1;
    wire [10:0] write_gray_next=(write_binary_next>>1)^write_binary_next;
    wire [10:0] full_compare={~read_gray_w2[10:9],read_gray_w2[8:0]};
    assign write_full=write_gray_next==full_compare;

    function [10:0] gray_to_binary;
        input [10:0] gray;integer bit_number;
        begin gray_to_binary[10]=gray[10];
            for(bit_number=9;bit_number>=0;bit_number=bit_number-1)
                gray_to_binary[bit_number]=gray_to_binary[bit_number+1]^gray[bit_number];
        end
    endfunction
    assign write_level=write_binary-gray_to_binary(read_gray_w2);

    always @(posedge write_clock)begin
        if(write_reset||write_clear)begin write_binary<=0;write_gray<=0;
            read_gray_w1<=0;read_gray_w2<=0;end
        else begin
            read_gray_w1<=read_gray;read_gray_w2<=read_gray_w1;
            if(write_enable&&!write_full)begin memory[write_binary[9:0]]<=write_data;
                write_binary<=write_binary_next;write_gray<=write_gray_next;end
        end
    end
    always @(posedge read_clock)begin
        if(read_reset||read_clear)begin read_binary<=0;read_gray<=0;
            write_gray_r1<=0;write_gray_r2<=0;read_data<=0;read_valid<=0;end
        else begin
            write_gray_r1<=write_gray;write_gray_r2<=write_gray_r1;
            if(!read_valid||read_pop)begin
                if(read_gray!=write_gray_r2)begin
                    read_data<=memory[read_binary[9:0]];read_binary<=read_binary+1'b1;
                    read_gray<=((read_binary+1'b1)>>1)^(read_binary+1'b1);read_valid<=1;
                end else read_valid<=0;
            end
        end
    end
endmodule

`default_nettype wire
