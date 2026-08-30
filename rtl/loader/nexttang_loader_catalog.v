// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Common loader policy above the FAT32 service. It discovers /games and the
// machine folder, catalogs files, provides a virtual BASIC entry, and turns a
// selected file into a typed byte stream for a core-specific consumer.
module nexttang_loader_catalog #(
    parameter integer MACHINE_KIND = 0, // 0=Classic48, 1=Classic128, 2=Spec256
    parameter integer MAX_ENTRIES = 32,
    parameter integer MAX_NAME = 48
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        storage_ready,
    input  wire        storage_busy,
    input  wire        storage_done,
    input  wire        storage_error,
    output reg         directory_start,
    output reg  [31:0] directory_cluster,
    input  wire        entry_valid,
    input  wire [7:0]  entry_attributes,
    input  wire [31:0] entry_cluster,
    input  wire [31:0] entry_size,
    input  wire [7:0]  entry_name_length,
    output reg  [7:0]  entry_name_index,
    input  wire [7:0]  entry_name_data,
    output reg         file_start,
    output reg  [31:0] file_cluster,
    output reg  [31:0] file_size,
    input  wire [7:0]  storage_file_byte,
    input  wire [31:0] storage_file_offset,
    input  wire        storage_file_valid,
    input  wire        navigate_up,
    input  wire        navigate_down,
    input  wire        activate,
    input  wire        open_menu,
    output reg         menu_ready,
    output reg         menu_active,
    output reg  [5:0]  selection,
    output reg  [5:0]  file_count,
    input  wire        display_clock,
    input  wire [5:0]  display_entry,
    input  wire [5:0]  display_name_index,
    output reg  [7:0]  display_name_data,
    output reg  [7:0]  display_name_length,
    output reg         basic_selected,
    output reg         content_start,
    output wire [7:0]  content_byte,
    output wire [31:0] content_offset,
    output wire        content_valid,
    output reg         content_done,
    output reg  [2:0]  content_format,
    output reg         error
);
    localparam [2:0] FORMAT_UNKNOWN=0, FORMAT_TAP=1, FORMAT_TZX=2,
                     FORMAT_SNA=3, FORMAT_Z80=4, FORMAT_NTSP=5;
    localparam [3:0] WAIT_VOLUME=0, START_ROOT=1, SCAN_ROOT=2,
                     CAPTURE_ROOT=3, START_GAMES=4, SCAN_GAMES=5,
                     CAPTURE_GAMES=6, START_TARGET=7, SCAN_TARGET=8,
                     CAPTURE_FILE=9, MENU=10, LOADING=11, RUNNING=12,
                     FAILED=13;
    reg [3:0] state = WAIT_VOLUME;
    reg [31:0] games_cluster = 0, target_cluster = 0;
    reg [31:0] candidate_cluster = 0, candidate_size = 0;
    reg [7:0] candidate_length = 0, capture_index = 0;
    reg candidate_match = 0, scan_finished = 0;
    reg [39:0] suffix = 0;
    reg [31:0] clusters [0:MAX_ENTRIES-1];
    reg [31:0] sizes [0:MAX_ENTRIES-1];
    reg [7:0] lengths [0:MAX_ENTRIES-1];
    reg [2:0] formats [0:MAX_ENTRIES-1];
    reg [7:0] names [0:MAX_ENTRIES*MAX_NAME-1];
    integer index;

    assign content_byte = storage_file_byte;
    assign content_offset = storage_file_offset;
    assign content_valid = state == LOADING && storage_file_valid;

    function [7:0] lower;
        input [7:0] character;
        begin lower = character >= "A" && character <= "Z" ?
            character + 8'd32 : character; end
    endfunction
    function [7:0] expected_games;
        input [7:0] offset;
        begin
            case(offset) 0:expected_games="g";1:expected_games="a";
                2:expected_games="m";3:expected_games="e";
                4:expected_games="s";default:expected_games=0;endcase
        end
    endfunction
    function [7:0] expected_target;
        input [7:0] offset;
        begin
            if (MACHINE_KIND == 0) begin
                case(offset) 0:expected_target="c";1:expected_target="l";
                2:expected_target="a";3:expected_target="s";4:expected_target="s";
                5:expected_target="i";6:expected_target="c";7:expected_target="4";
                8:expected_target="8";default:expected_target=0;endcase
            end else if (MACHINE_KIND == 1) begin
                case(offset) 0:expected_target="c";1:expected_target="l";
                2:expected_target="a";3:expected_target="s";4:expected_target="s";
                5:expected_target="i";6:expected_target="c";7:expected_target="1";
                8:expected_target="2";9:expected_target="8";default:expected_target=0;endcase
            end else begin
                case(offset) 0:expected_target="s";1:expected_target="p";
                2:expected_target="e";3:expected_target="c";4:expected_target="2";
                5:expected_target="5";6:expected_target="6";default:expected_target=0;endcase
            end
        end
    endfunction
    function [7:0] target_length;
        begin target_length = MACHINE_KIND == 0 ? 9 : MACHINE_KIND == 1 ? 10 : 7; end
    endfunction
    function [2:0] suffix_format;
        input [39:0] value;
        begin
            if (MACHINE_KIND == 2) suffix_format = FORMAT_NTSP;
            else if (value[31:0] == 32'h2e746170) suffix_format = FORMAT_TAP;
            else if (value[31:0] == 32'h2e747a78) suffix_format = FORMAT_TZX;
            else if (value[31:0] == 32'h2e736e61) suffix_format = FORMAT_SNA;
            else if (value[31:0] == 32'h2e7a3830) suffix_format = FORMAT_Z80;
            else if (value == 40'h2e6e747370) suffix_format = FORMAT_NTSP;
            else suffix_format = FORMAT_UNKNOWN;
        end
    endfunction

    // A synchronous, single-address name read lets Gowin infer BSRAM.  An
    // asynchronous 1,536-byte table becomes a huge cross-chip mux and made the
    // otherwise modest loader unroutable beside the DDR hard interface.
    reg [10:0] display_name_address=0;
    reg [4:0] display_length_address=0;
    reg [5:0] display_name_index_q=0;
    reg display_basic_q=0,display_valid_q=0;
    always @(posedge display_clock) begin
        display_name_address <= (display_entry-1)*MAX_NAME + display_name_index;
        display_length_address <= display_entry-1'b1;
        display_name_index_q <= display_name_index;
        display_basic_q <= display_entry==0;
        display_valid_q <= display_entry!=0 && display_entry<=file_count &&
                           display_name_index<MAX_NAME;
        if (display_basic_q) begin
            display_name_length <= 5;
            if (MACHINE_KIND == 2) begin
                case(display_name_index_q) 0:display_name_data<="P";1:display_name_data<="A";
                    2:display_name_data<="C";3:display_name_data<="K";
                    4:display_name_data<="S";default:display_name_data<=0;endcase
            end else begin
                case(display_name_index_q) 0:display_name_data<="B";1:display_name_data<="A";
                    2:display_name_data<="S";3:display_name_data<="I";
                    4:display_name_data<="C";default:display_name_data<=0;endcase
            end
        end else if (display_valid_q) begin
            display_name_data <= names[display_name_address];
            display_name_length <= lengths[display_length_address];
        end else begin display_name_data <= 0; display_name_length <= 0; end
    end

    always @(posedge clock) begin
        if (reset) begin
            state<=WAIT_VOLUME;directory_start<=0;directory_cluster<=0;
            entry_name_index<=0;file_start<=0;file_cluster<=0;file_size<=0;
            menu_ready<=0;menu_active<=1;selection<=0;file_count<=0;
            basic_selected<=0;content_start<=0;content_done<=0;
            content_format<=FORMAT_UNKNOWN;error<=0;games_cluster<=0;
            target_cluster<=0;candidate_cluster<=0;candidate_size<=0;
            candidate_length<=0;capture_index<=0;candidate_match<=0;
            scan_finished<=0;suffix<=0;
            for(index=0;index<MAX_ENTRIES;index=index+1)begin
                clusters[index]<=0;sizes[index]<=0;lengths[index]<=0;formats[index]<=0;end
        end else begin
            directory_start<=0;file_start<=0;basic_selected<=0;
            content_start<=0;content_done<=0;
            if(storage_error)state<=FAILED;
            case(state)
                WAIT_VOLUME:if(storage_ready)state<=START_ROOT;
                START_ROOT:begin directory_cluster<=0;directory_start<=1;
                    scan_finished<=0;state<=SCAN_ROOT;end
                SCAN_ROOT:begin
                    if(storage_done)begin scan_finished<=1;if(games_cluster!=0)state<=START_GAMES;
                        else state<=FAILED;end
                    else if(entry_valid&&(entry_attributes&8'h10))begin
                        candidate_cluster<=entry_cluster;candidate_length<=entry_name_length;
                        capture_index<=0;entry_name_index<=0;
                        candidate_match<=entry_name_length==5;state<=CAPTURE_ROOT;end
                end
                CAPTURE_ROOT:begin
                    if(lower(entry_name_data)!=expected_games(capture_index))candidate_match<=0;
                    if(capture_index+1>=candidate_length)begin
                        if(candidate_match&&lower(entry_name_data)==expected_games(capture_index))
                            games_cluster<=candidate_cluster;
                        state<=scan_finished?(games_cluster!=0?START_GAMES:FAILED):SCAN_ROOT;
                    end else begin capture_index<=capture_index+1'b1;entry_name_index<=capture_index+1'b1;end
                end
                START_GAMES:begin directory_cluster<=games_cluster;directory_start<=1;
                    scan_finished<=0;state<=SCAN_GAMES;end
                SCAN_GAMES:begin
                    if(storage_done)begin scan_finished<=1;if(target_cluster!=0)state<=START_TARGET;
                        else state<=FAILED;end
                    else if(entry_valid&&(entry_attributes&8'h10))begin
                        candidate_cluster<=entry_cluster;candidate_length<=entry_name_length;
                        capture_index<=0;entry_name_index<=0;
                        candidate_match<=entry_name_length==target_length();state<=CAPTURE_GAMES;end
                end
                CAPTURE_GAMES:begin
                    if(lower(entry_name_data)!=expected_target(capture_index))candidate_match<=0;
                    if(capture_index+1>=candidate_length)begin
                        if(candidate_match&&lower(entry_name_data)==expected_target(capture_index))
                            target_cluster<=candidate_cluster;
                        state<=scan_finished?(target_cluster!=0?START_TARGET:FAILED):SCAN_GAMES;
                    end else begin capture_index<=capture_index+1'b1;entry_name_index<=capture_index+1'b1;end
                end
                START_TARGET:begin directory_cluster<=target_cluster;directory_start<=1;
                    file_count<=0;scan_finished<=0;state<=SCAN_TARGET;end
                SCAN_TARGET:begin
                    if(storage_done)begin menu_ready<=1;menu_active<=1;
                        selection<=MACHINE_KIND==2?6'd1:6'd0;state<=MENU;end
                    else if(entry_valid&&!(entry_attributes&8'h18)&&file_count<MAX_ENTRIES)begin
                        candidate_cluster<=entry_cluster;candidate_size<=entry_size;
                        candidate_length<=entry_name_length>MAX_NAME?MAX_NAME:entry_name_length;
                        capture_index<=0;entry_name_index<=0;suffix<=0;state<=CAPTURE_FILE;end
                end
                CAPTURE_FILE:begin
                    names[file_count*MAX_NAME+capture_index]<=entry_name_data;
                    suffix<={suffix[31:0],lower(entry_name_data)};
                    if(capture_index+1>=candidate_length)begin
                        // Classic machines currently consume tape streams;
                        // snapshots remain invisible until their atomic CPU/RAM
                        // restore path exists.  Spec256 accepts only its pack.
                        if ((MACHINE_KIND==2 && suffix_format({suffix[31:0],lower(entry_name_data)})==FORMAT_NTSP) ||
                            (MACHINE_KIND!=2 && (suffix_format({suffix[31:0],lower(entry_name_data)})==FORMAT_TAP ||
                                                suffix_format({suffix[31:0],lower(entry_name_data)})==FORMAT_TZX))) begin
                            clusters[file_count]<=candidate_cluster;sizes[file_count]<=candidate_size;
                            lengths[file_count]<=candidate_length;
                            formats[file_count]<=suffix_format({suffix[31:0],lower(entry_name_data)});
                            file_count<=file_count+1'b1;
                        end
                        state<=SCAN_TARGET;
                    end else begin capture_index<=capture_index+1'b1;entry_name_index<=capture_index+1'b1;end
                end
                MENU:begin
                    if(navigate_up)selection<=MACHINE_KIND==2?
                        (selection<=1?file_count:selection-1'b1):
                        (selection==0?file_count:selection-1'b1);
                    else if(navigate_down)selection<=MACHINE_KIND==2?
                        (selection>=file_count?6'd1:selection+1'b1):
                        (selection>=file_count?6'd0:selection+1'b1);
                    if(activate)begin
                        if(selection==0&&MACHINE_KIND!=2)begin basic_selected<=1;menu_active<=0;state<=RUNNING;end
                        else begin file_cluster<=clusters[selection-1];file_size<=sizes[selection-1];
                            content_format<=formats[selection-1];file_start<=1;content_start<=1;
                            menu_active<=0;state<=LOADING;end
                    end
                end
                LOADING:if(storage_done)begin content_done<=1;menu_active<=0;state<=RUNNING;end
                RUNNING:if(open_menu)begin menu_active<=1;state<=MENU;end
                default:begin error<=1;menu_ready<=0;menu_active<=1;state<=FAILED;end
            endcase
        end
    end
endmodule

`default_nettype wire
