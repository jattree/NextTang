// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Expand a TAP byte stream into the bounded TZX subset used by the player.
module nexttang_tap_to_tzx_stream (
    input  wire       clock,
    input  wire       reset,
    input  wire       start,
    input  wire [7:0] input_byte,
    input  wire       input_valid,
    input  wire       input_done,
    output reg  [7:0] output_byte,
    output reg        output_valid,
    output reg        output_done,
    output wire       pause_input,
    output reg        fault
);
    localparam [2:0] HEADER=0,LENGTH_LOW=1,LENGTH_HIGH=2,
                     BLOCK_HEADER=3,DATA=4,FINISH=5;
    reg [2:0] state=LENGTH_LOW;
    reg [3:0] emit_index=0;
    reg [15:0] block_length=0,remaining=0;
    assign pause_input=state==HEADER||state==BLOCK_HEADER;
    function [7:0] header_byte;
        input[3:0]number;
        begin case(number)0:header_byte="Z";1:header_byte="X";2:header_byte="T";
        3:header_byte="a";4:header_byte="p";5:header_byte="e";6:header_byte="!";
        7:header_byte=8'h1a;8:header_byte=8'h01;default:header_byte=8'h14;endcase end
    endfunction
    function [7:0] block_header_byte;
        input[2:0]number;
        begin case(number)0:block_header_byte=8'h10;1:block_header_byte=8'he8;
        2:block_header_byte=8'h03;3:block_header_byte=block_length[7:0];
        default:block_header_byte=block_length[15:8];endcase end
    endfunction
    always @(posedge clock)begin
        if(reset)begin state<=LENGTH_LOW;emit_index<=0;block_length<=0;remaining<=0;
            output_byte<=0;output_valid<=0;output_done<=0;fault<=0;end
        else begin
            output_valid<=0;output_done<=0;
            if(start)begin state<=HEADER;emit_index<=0;fault<=0;end
            else case(state)
                HEADER:begin output_byte<=header_byte(emit_index);output_valid<=1;
                    if(emit_index==9)begin emit_index<=0;state<=LENGTH_LOW;end
                    else emit_index<=emit_index+1'b1;end
                LENGTH_LOW:begin
                    if(input_valid)begin block_length[7:0]<=input_byte;state<=LENGTH_HIGH;end
                    else if(input_done)state<=FINISH;end
                LENGTH_HIGH:if(input_valid)begin
                    block_length[15:8]<=input_byte;
                    remaining<={input_byte,block_length[7:0]};emit_index<=0;
                    if({input_byte,block_length[7:0]}==0)begin fault<=1;state<=FINISH;end
                    else state<=BLOCK_HEADER;end
                BLOCK_HEADER:begin output_byte<=block_header_byte(emit_index);output_valid<=1;
                    if(emit_index==4)begin emit_index<=0;state<=DATA;end
                    else emit_index<=emit_index+1'b1;end
                DATA:if(input_valid)begin output_byte<=input_byte;output_valid<=1;
                    if(remaining==1)begin remaining<=0;state<=LENGTH_LOW;end
                    else remaining<=remaining-1'b1;end
                FINISH:begin output_done<=1;state<=LENGTH_LOW;end
                default:begin fault<=1;state<=FINISH;end
            endcase
            if(input_valid&&pause_input)fault<=1;
            if(input_done&&state!=LENGTH_LOW&&state!=FINISH)begin fault<=1;state<=FINISH;end
        end
    end
endmodule

`default_nettype wire
