// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Owns the ZX Spectrum 128K memory map so that no other module needs to know
// the paging rules.
//
// Port 0x7FFD is decoded on A15 and A1 alone, as the original did, so any
// address with both low reaches it. The value it holds fixes four things:
//
//   bits 2:0  the RAM bank paged into 0xC000-0xFFFF
//   bit 3     the displayed screen, bank 5 when clear and bank 7 when set
//   bit 4     the ROM, 0 is the 128K editor and 1 is 48K BASIC
//   bit 5     paging lock; once set nothing changes again until a reset
//
// The rest of the map is fixed: ROM at 0x0000, bank 5 at 0x4000 and bank 2 at
// 0x8000. Bank 5 therefore appears twice whenever it is also selected at
// 0xC000, which is real behaviour that software relies on.

`default_nettype none

module nexttang_spectrum_paging (
    input  wire        clock,
    input  wire        reset,

    // Machine-side port writes. `io_write` is a single-cycle strobe.
    input  wire        io_write,
    input  wire [15:0] io_address,
    input  wire [7:0]  io_data,

    // Combinational translation for the address the CPU is presenting.
    input  wire [15:0] cpu_address,
    output wire        cpu_is_rom,
    output wire [2:0]  cpu_bank,

    output wire        rom_select,
    output wire        screen_bank,
    output wire        paging_locked
);
    reg [5:0] port = 6'b0;
    reg locked = 1'b0;

    wire selected = !io_address[15] && !io_address[1];

    always @(posedge clock) begin
        if (reset) begin
            port <= 6'b0;
            locked <= 1'b0;
        end else if (io_write && selected && !locked) begin
            port <= io_data[5:0];
            locked <= io_data[5];
        end
    end

    assign rom_select = port[4];
    assign screen_bank = port[3];
    assign paging_locked = locked;

    assign cpu_is_rom = cpu_address[15:14] == 2'b00;
    assign cpu_bank = cpu_address[15:14] == 2'b01 ? 3'd5 :
                      cpu_address[15:14] == 2'b10 ? 3'd2 :
                      port[2:0];
endmodule

`default_nettype wire
