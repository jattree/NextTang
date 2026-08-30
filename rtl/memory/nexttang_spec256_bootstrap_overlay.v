// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors

`default_nettype none

// Loader-writable Spec256 snapshot bootstrap. The generated bootstrap occupies
// 69 bytes; the pack's remaining 16 KiB field is zero padding. Retain the full
// 14-bit read contract by returning zero outside the first 256-byte page while
// avoiding a 16 KiB distributed-RAM mux cone.
module nexttang_spec256_bootstrap_overlay (
    input  wire        clock,
    input  wire        write_enable,
    input  wire [13:0] write_address,
    input  wire [7:0]  write_data,
    input  wire [13:0] read_address,
    output wire [7:0]  read_data
);
    wire [7:0] page_data;
    wire page_write = write_enable && write_address[13:8] == 6'b0;
    reg read_in_page = 1'b0;

    nexttang_distributed_ram #(.ADDRESS_BITS(8)) page (
        .clock(clock),
        .write_enable(page_write),
        .address(page_write ? write_address[7:0] : read_address[7:0]),
        .write_data(write_data),
        .read_data(page_data)
    );

    // Match the synchronous RAM output with the high address bits captured on
    // the same edge. This prevents addresses above 0x00ff aliasing the page.
    always @(posedge clock)
        if (!page_write)
            read_in_page <= read_address[13:8] == 6'b0;

    assign read_data = read_in_page ? page_data : 8'h00;
endmodule

`default_nettype wire
