// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Turn the ZXNext core's own reset requests into its reset inputs.
//
// NextREG 0x02 lets software ask for a soft reset (restart with the NextREGs
// kept) or a hard reset. A real Next answers a hard reset by reconfiguring
// the FPGA, which brings the machine back through the boot ROM; here that is
// i_BOOT held with i_RESET. A change of video timing (NextREG 0x11) also
// restarts the machine, as the official and MiSTer tops do. Each request
// holds the reset for 1024 cycles of clock_28, MiSTer's length.

`default_nettype none

module nexttang_zxnext_core_reset (
    input  wire       clock_28,
    input  wire       machine_reset,
    input  wire       soft_request,
    input  wire       hard_request,
    input  wire [2:0] video_mode,
    output wire       core_reset,
    output wire       core_boot
);
    reg [9:0] counter = 10'd0;
    reg       boot_pending = 1'b0;
    reg [2:0] actual_video_mode = 3'd0;

    always @(posedge clock_28) begin
        if (machine_reset) begin
            counter <= 10'd0;
            boot_pending <= 1'b0;
            actual_video_mode <= video_mode;
        end else if (soft_request || hard_request || video_mode != actual_video_mode) begin
            counter <= 10'h3ff;
            boot_pending <= boot_pending || hard_request;
            actual_video_mode <= video_mode;
        end else if (counter != 10'd0) begin
            counter <= counter - 10'd1;
        end else begin
            boot_pending <= 1'b0;
        end
    end

    assign core_reset = machine_reset || counter != 10'd0;
    assign core_boot = machine_reset || (boot_pending && counter != 10'd0);
endmodule

`default_nettype wire
