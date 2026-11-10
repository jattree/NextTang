// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Atomic consumer for the bounded NTPK v1 format produced by tools/poke.py.
// Records are buffered and CRC-checked before any memory write is exposed.
module nexttang_poke_loader #(
    parameter integer MACHINE_KIND = 0,
    parameter integer MAX_RECORDS = 8
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        content_start,
    input  wire [7:0]  byte_data,
    input  wire        byte_valid,
    input  wire        content_done,
    output wire        hold_cpu,
    output reg         ready,
    output reg         fault,
    output wire        write_valid,
    input  wire        write_ready,
    output wire [1:0]  write_target,
    output wire [2:0]  write_bank,
    output wire [15:0] write_address,
    output wire [7:0]  write_data
);
    localparam [2:0] IDLE=0, HEADER_STATE=1, PAYLOAD=2,
                     VERIFY=3, APPLY=4, DONE=5, FAILED=6;
    localparam integer HEADER_BYTES=16, RECORD_BYTES=6;

    reg [2:0] state=IDLE;
    reg [4:0] header_index=0;
    reg header_bad=0;
    reg [31:0] record_count=0,expected_crc=0,running_crc=32'hffffffff;
    reg [15:0] payload_index=0;
    reg [6:0] captured_records=0,apply_index=0;
    reg [1:0] capture_target=0;
    reg [2:0] capture_bank=0;
    reg [15:0] capture_address=0;
    (* syn_ramstyle = "registers" *) reg [1:0] targets[0:MAX_RECORDS-1];
    (* syn_ramstyle = "registers" *) reg [2:0] banks[0:MAX_RECORDS-1];
    (* syn_ramstyle = "registers" *) reg [15:0] addresses[0:MAX_RECORDS-1];
    (* syn_ramstyle = "registers" *) reg [7:0] values[0:MAX_RECORDS-1];

    function [31:0] crc32_byte;
        input [31:0] crc; input [7:0] data;
        integer bit_index; reg [31:0] value;
        begin
            value=crc^data;
            for(bit_index=0;bit_index<8;bit_index=bit_index+1)
                value=value[0]?(value>>1)^32'hedb88320:value>>1;
            crc32_byte=value;
        end
    endfunction

    function record_valid;
        input [1:0] target; input [2:0] bank;
        input [15:0] address; input [7:0] reserved;
        begin
            record_valid=reserved==0;
            case(target)
                0:record_valid=record_valid&&bank==0&&address>=16'h4000;
                1:record_valid=record_valid&&MACHINE_KIND==1&&address<=16'h3fff;
                2:record_valid=record_valid&&MACHINE_KIND==2&&address>=16'h4000;
                3:record_valid=record_valid&&MACHINE_KIND==2&&bank==0&&address>=16'h4000;
                default:record_valid=1'b0;
            endcase
        end
    endfunction

    assign hold_cpu=state==HEADER_STATE||state==PAYLOAD||state==VERIFY||state==APPLY;
    assign write_valid=state==APPLY;
    assign write_target=targets[apply_index];
    assign write_bank=banks[apply_index];
    assign write_address=addresses[apply_index];
    assign write_data=values[apply_index];

    always @(posedge clock) begin
        if(reset)begin state<=IDLE;ready<=0;fault<=0;header_index<=0;
            header_bad<=0;record_count<=0;expected_crc<=0;running_crc<=32'hffffffff;
            payload_index<=0;captured_records<=0;apply_index<=0;end
        else begin
            if(content_start)begin state<=HEADER_STATE;ready<=0;fault<=0;
                header_index<=0;header_bad<=0;record_count<=0;expected_crc<=0;
                running_crc<=32'hffffffff;payload_index<=0;
                captured_records<=0;apply_index<=0;end
            else if(byte_valid&&state==IDLE)begin
                state<=HEADER_STATE;ready<=0;fault<=0;header_index<=1;
                header_bad<=byte_data!="N";record_count<=0;expected_crc<=0;
                running_crc<=32'hffffffff;payload_index<=0;
                captured_records<=0;apply_index<=0;
            end
            else if(byte_valid&&(state==DONE||state==FAILED)&&byte_data=="N")begin
                state<=HEADER_STATE;ready<=0;fault<=0;header_index<=1;
                header_bad<=0;record_count<=0;expected_crc<=0;
                running_crc<=32'hffffffff;payload_index<=0;
                captured_records<=0;apply_index<=0;
            end
            else if(byte_valid&&state==HEADER_STATE)begin
                case(header_index)
                    0:if(byte_data!="N")header_bad<=1;
                    1:if(byte_data!="T")header_bad<=1;
                    2:if(byte_data!="P")header_bad<=1;
                    3:if(byte_data!="K")header_bad<=1;
                    4:if(byte_data!=1)header_bad<=1;
                    5:if(byte_data!=MACHINE_KIND)header_bad<=1;
                    6:if(byte_data!=RECORD_BYTES)header_bad<=1;
                    7:if(byte_data!=0)header_bad<=1;
                    8:record_count[7:0]<=byte_data;
                    9:record_count[15:8]<=byte_data;
                    10:record_count[23:16]<=byte_data;
                    11:begin record_count[31:24]<=byte_data;
                        if(byte_data!=0||record_count[23:0]>MAX_RECORDS)header_bad<=1;end
                    12:expected_crc[7:0]<=byte_data;
                    13:expected_crc[15:8]<=byte_data;
                    14:expected_crc[23:16]<=byte_data;
                    15:begin expected_crc[31:24]<=byte_data;
                        if(header_bad)begin state<=FAILED;fault<=1;end
                        else if(record_count==0)state<=VERIFY;
                        else state<=PAYLOAD;end
                    default:;
                endcase
                if(header_index!=HEADER_BYTES-1)header_index<=header_index+1'b1;
            end else if(byte_valid&&state==PAYLOAD)begin
                running_crc<=crc32_byte(running_crc,byte_data);
                case(payload_index%RECORD_BYTES)
                    0:begin capture_target<=byte_data[1:0];
                        if(byte_data>3)header_bad<=1;end
                    1:begin capture_bank<=byte_data[2:0];
                        if(byte_data>7)header_bad<=1;end
                    2:capture_address[7:0]<=byte_data;
                    3:capture_address[15:8]<=byte_data;
                    4:begin targets[captured_records]<=capture_target;
                        banks[captured_records]<=capture_bank;
                        addresses[captured_records]<=capture_address;
                        values[captured_records]<=byte_data;end
                    5:begin
                        if(!record_valid(capture_target,capture_bank,capture_address,byte_data))
                            header_bad<=1;
                        captured_records<=captured_records+1'b1;
                    end
                    default:;
                endcase
                payload_index<=payload_index+1'b1;
                if(payload_index+1==record_count*RECORD_BYTES)state<=VERIFY;
            end else if(state==VERIFY&&content_done)begin
                if(header_bad||captured_records!=record_count||
                   ~running_crc!=expected_crc)begin state<=FAILED;fault<=1;end
                else if(record_count==0)begin state<=DONE;ready<=1;end
                else begin state<=APPLY;apply_index<=0;end
            end else if(state==APPLY&&write_ready)begin
                if(apply_index+1==record_count)begin state<=DONE;ready<=1;end
                else apply_index<=apply_index+1'b1;
            end else if(content_done&&(state==HEADER_STATE||state==PAYLOAD))begin
                state<=FAILED;fault<=1;
            end
        end
    end
endmodule

`default_nettype wire
