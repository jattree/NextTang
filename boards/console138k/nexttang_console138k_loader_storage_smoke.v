// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Exact-device synthesis and later pin-level smoke target for the native
// read-only SD/FAT32/common-loader stack. It never issues an SD write command.
module nexttang_console138k_loader_storage_smoke (
    input  wire sys_clk,
    input  wire loader_up,
    input  wire loader_down,
    input  wire loader_activate,
    input  wire sd_miso,
    output wire sd_clk,
    output wire sd_mosi,
    output wire sd_cs,
    output wire status_led,
    output wire debug_probe
);
    reg [7:0] reset_shift = 0;
    always @(posedge sys_clk) reset_shift <= {reset_shift[6:0],1'b1};
    wire reset = !reset_shift[7];

    wire storage_ready,storage_busy,storage_done,storage_error;
    wire entry_valid;wire[7:0]entry_attributes;wire[31:0]entry_cluster,entry_size;
    wire[7:0]entry_name_length,entry_name_data;wire[7:0]entry_name_index;
    wire directory_start;wire[31:0]directory_cluster;
    wire file_start;wire[31:0]file_cluster,file_size;
    wire[7:0]file_byte;wire[31:0]file_offset;wire file_byte_valid;
    wire menu_ready,menu_active,basic_selected,content_start,content_valid,content_done;
    wire[5:0]selection,file_count;wire[2:0]content_format;wire loader_error;
    wire[7:0]content_byte;wire[31:0]content_offset;
    wire[5:0]display_entry=selection,display_name_index=0;
    wire[7:0]display_name_data,display_name_length;

    nexttang_fat32_storage #(.CLOCK_HZ(50_000_000)) storage(
        .clock(sys_clk),.reset(reset),.directory_start(directory_start),
        .directory_cluster(directory_cluster),.file_start(file_start),
        .file_cluster(file_cluster),.file_size(file_size),.file_pause(1'b0),.entry_valid(entry_valid),
        .entry_attributes(entry_attributes),.entry_cluster(entry_cluster),
        .entry_size(entry_size),.entry_name_length(entry_name_length),
        .entry_name_index(entry_name_index),.entry_name_data(entry_name_data),
        .file_byte(file_byte),.file_offset(file_offset),.file_byte_valid(file_byte_valid),
        .ready(storage_ready),.busy(storage_busy),.operation_done(storage_done),
        .error(storage_error),.sd_clk(sd_clk),.sd_mosi(sd_mosi),
        .sd_miso(sd_miso),.sd_cs(sd_cs));

    nexttang_loader_catalog #(.MACHINE_KIND(0)) loader(
        .clock(sys_clk),.reset(reset),.storage_ready(storage_ready),
        .storage_busy(storage_busy),.storage_done(storage_done),
        .storage_error(storage_error),.directory_start(directory_start),
        .directory_cluster(directory_cluster),.entry_valid(entry_valid),
        .entry_attributes(entry_attributes),.entry_cluster(entry_cluster),
        .entry_size(entry_size),.entry_name_length(entry_name_length),
        .entry_name_index(entry_name_index),.entry_name_data(entry_name_data),
        .file_start(file_start),.file_cluster(file_cluster),.file_size(file_size),
        .storage_file_byte(file_byte),.storage_file_offset(file_offset),
        .storage_file_valid(file_byte_valid),.navigate_up(loader_up),
        .navigate_down(loader_down),.activate(loader_activate),.open_menu(1'b0),
        .menu_ready(menu_ready),.menu_active(menu_active),.selection(selection),
        .file_count(file_count),.display_clock(sys_clk),.display_entry(display_entry),
        .display_name_index(display_name_index),.display_name_data(display_name_data),
        .display_name_length(display_name_length),.basic_selected(basic_selected),
        .content_start(content_start),.content_byte(content_byte),
        .content_offset(content_offset),.content_valid(content_valid),
        .content_done(content_done),.content_format(content_format),.error(loader_error));

    assign status_led=menu_ready&&!storage_error&&!loader_error;
    assign debug_probe=storage_busy^storage_done^entry_valid^file_byte_valid^
        menu_active^basic_selected^content_start^content_valid^content_done^
        ^entry_attributes^entry_cluster[0]^entry_size[0]^entry_name_data[0]^
        (^selection)^(^file_count)^(^content_format)^content_byte[0]^content_offset[0];
endmodule

`default_nettype wire
