// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// Where HDMI data islands and video guard bands go in hdmi_frame's output.
//
// hdmi_frame (rtl/video/hdmi_frame.vhd) makes the frame: its registered
// o_blank, o_hsync_n and o_vsync_n describe the counter position of the cycle
// before. This module rebuilds that position from the syncs alone, so the
// official frame code needs no new outputs:
//   x: the falling edge of hsync is position HSYNC_BEG; a free-running count
//      wraps after HLAST and is checked against every hsync.
//   y: the rising edge of vsync is the first line after VSYNC_END. The lines
//      from there to VLAST, the end of the active picture, never vary;
//      hdmi_frame's re-lock (G_RELOCK) only lengthens or shortens the front
//      porch, before vsync, where this module just waits for the next vsync.
//
// hdmi_frame's line has its blanking first: positions 0 to HACTIVE-1 are
// blank, HACTIVE to HLAST active, on lines VACTIVE to VLAST. Each line then
// carries, from position 0 (after the previous line's video, HDMI 1.4 5.2):
//   0-3      control period (at least 4)
//   4-11     data island preamble
//   12-13    data island leading guard band
//   14-45    one 32-pixel packet
//   46-47    data island trailing guard band
//   ...      control
//   HACTIVE-10 to HACTIVE-3   video preamble   (lines with active video)
//   HACTIVE-2, HACTIVE-1      video guard band (lines with active video)
// as the hdl-util transmitter places them after its video (rtl/video/hdmi/
// hdmi.sv: one packet per island, an island on every line).
//
// The sync levels are passed as sent (CEA 576p and 480p syncs are negative).
// Outputs are one cycle after the inputs (stage 1); packet_enable and
// field_end are combinational at the inputs' cycle (stage 0), where the
// packet picker wants them. Until a vsync has been seen with hsyncs where they
// were expected, no island or guard band is sent and the output is plain DVI.

`default_nettype none

module nexttang_hdmi_island_timing (
    input  wire       clock,
    input  wire       reset,
    input  wire [9:0] hactive,
    input  wire [9:0] hsync_beg,
    input  wire [9:0] hlast,
    input  wire [9:0] vactive,
    input  wire [9:0] vsync_end,
    input  wire [9:0] vlast,

    // hdmi_frame's outputs
    input  wire       blank,
    input  wire       hsync_n,
    input  wire       vsync_n,
    input  wire [8:0] rgb,

    // stage 0
    output wire       packet_enable,
    output wire       field_end,

    // stage 1
    output reg        island_preamble = 1'b0,
    output reg        island_guard = 1'b0,
    output reg        island_period = 1'b0,
    output reg        island_first = 1'b0,
    output reg        video_preamble = 1'b0,
    output reg        video_guard = 1'b0,
    output reg        video_period = 1'b0,
    output reg        line_start = 1'b0,   // position 0: no island in progress
    output reg        hsync_level = 1'b1,  // the sync lines as sent (active low)
    output reg        vsync_level = 1'b1,
    output reg  [8:0] video = 9'd0,
    output reg        locked = 1'b0
);
    reg       hsync_n_seen = 1'b1;
    reg       vsync_n_seen = 1'b1;
    reg [9:0] x_next = 10'd0;
    reg [9:0] y = 10'd0;
    reg       in_picture = 1'b0;     // between the end of vsync and VLAST
    reg       line_locked = 1'b0;    // locked, sampled at position 0

    wire hsync_fall = !hsync_n && hsync_n_seen;
    wire vsync_rise = vsync_n && !vsync_n_seen;
    wire [9:0] x = hsync_fall ? hsync_beg : x_next;
    wire line_end = x == hlast;
    // the line this position is on has active video
    wire active_line = in_picture && y >= vactive;

    always @(posedge clock) begin
        hsync_n_seen <= hsync_n;
        vsync_n_seen <= vsync_n;
        x_next <= line_end ? 10'd0 : x + 10'd1;
        if (reset) begin
            locked <= 1'b0;
            in_picture <= 1'b0;
        end else begin
            if (hsync_fall && x_next != hsync_beg)
                locked <= 1'b0;
            if (vsync_rise) begin
                // vsync ends as a line starts: this is position 0 of line
                // VSYNC_END + 1
                y <= vsync_end + 10'd1;
                in_picture <= 1'b1;
                if (x_next == 10'd0)
                    locked <= 1'b1;
                else
                    locked <= 1'b0;
            end else if (line_end) begin
                y <= y + 10'd1;
                if (y == vlast)
                    in_picture <= 1'b0;
            end
        end
    end

    // islands start only on a whole line
    always @(posedge clock)
        if (reset)
            line_locked <= 1'b0;
        else if (line_end)
            line_locked <= locked && !(vsync_rise && x_next != 10'd0);

    // decided per line, so an island is never cut short
    wire send = line_locked;
    assign packet_enable = send && x == 10'd14;
    assign field_end = send && line_end && in_picture && y == vlast;

    always @(posedge clock) begin
        island_preamble <= send && x >= 10'd4 && x < 10'd12;
        island_guard <= send && (x == 10'd12 || x == 10'd13 || x == 10'd46 || x == 10'd47);
        island_period <= send && x >= 10'd14 && x < 10'd46;
        island_first <= send && x == 10'd14;
        video_preamble <= send && active_line && x >= hactive - 10'd10 && x < hactive - 10'd2;
        video_guard <= send && active_line && x >= hactive - 10'd2 && x < hactive;
        video_period <= !blank;
        line_start <= x == 10'd0;
        hsync_level <= hsync_n;
        vsync_level <= vsync_n;
        video <= rgb;
    end
endmodule

`default_nettype wire
