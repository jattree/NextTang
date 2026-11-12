// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// nexttang_hdmi_island_timing against a model of hdmi_frame's output: its
// registered blank and syncs from the same counters, with the front porch
// lengthened or shortened every frame as G_RELOCK does. Checks, on every line
// after lock: one island (preamble 8, guard 2, packet 32, guard 2) at
// positions 4-47, never touching video or the video guard; a video preamble
// and guard band right before each line's video and on no other line; field_end
// once per frame on the last active pixel.
`timescale 1ns/1ps
`default_nettype none
module tb_hdmi_island_timing;
    parameter integer VIDEO_60 = 0;
    parameter integer FRAMES = 8;
    localparam [9:0] HACTIVE = VIDEO_60 ? 10'd138 : 10'd144;
    localparam [9:0] HSYNC_BEG = VIDEO_60 ? 10'd16 : 10'd12;
    localparam [9:0] HSYNC_END = VIDEO_60 ? 10'd77 : 10'd75;
    localparam [9:0] HLAST = VIDEO_60 ? 10'd857 : 10'd863;
    localparam [9:0] VACTIVE = VIDEO_60 ? 10'd45 : 10'd49;
    localparam [9:0] VSYNC_BEG = VIDEO_60 ? 10'd9 : 10'd5;
    localparam [9:0] VSYNC_END = VIDEO_60 ? 10'd14 : 10'd9;
    localparam [9:0] VLAST = VIDEO_60 ? 10'd524 : 10'd624;

    reg clock = 1'b0;
    always #18.5 clock = !clock;
    reg reset = 1'b1;

    // hdmi_frame's counters and registered outputs
    reg [9:0] hcnt = 10'd0, vcnt = 10'd0;
    reg blank = 1'b1, hsync_n = 1'b1, vsync_n = 1'b1;
    reg [9:0] hcnt_q = 10'd0, vcnt_q = 10'd0;   // the position the outputs describe
    integer extra = 0;          // this frame's front porch change, lines
    integer hold = 0;
    integer frame = 0;
    always @(posedge clock) begin
        if (hcnt == HLAST) begin
            hcnt <= 10'd0;
            if (vcnt == VLAST) begin
                vcnt <= 10'd0;
                frame <= frame + 1;
                // as G_RELOCK: from -(VSYNC_BEG-1) to +40 lines
                extra = (frame * 37 + 11) % 45 - 4;
                if (extra > 40) extra = 40;
                hold = extra > 0 ? extra : 0;
            end else if (vcnt == 0 && extra < 0) begin
                vcnt <= 1 - extra;
                extra = 0;
            end else if (vcnt == VSYNC_BEG - 1 && hold != 0) begin
                hold = hold - 1;
            end else begin
                vcnt <= vcnt + 10'd1;
            end
        end else begin
            hcnt <= hcnt + 10'd1;
        end
        hsync_n <= !(hcnt >= HSYNC_BEG && hcnt <= HSYNC_END);
        vsync_n <= !(vcnt >= VSYNC_BEG && vcnt <= VSYNC_END);
        blank <= !(hcnt >= HACTIVE && vcnt >= VACTIVE);
        hcnt_q <= hcnt;
        vcnt_q <= vcnt;
    end

    wire packet_enable, field_end;
    wire island_preamble, island_guard, island_period, island_first;
    wire video_preamble, video_guard, video_period, line_start;
    wire hsync_level, vsync_level, locked;
    wire [8:0] video;
    nexttang_hdmi_island_timing dut (
        .clock(clock), .reset(reset),
        .hactive(HACTIVE), .hsync_beg(HSYNC_BEG), .hlast(HLAST),
        .vactive(VACTIVE), .vsync_end(VSYNC_END), .vlast(VLAST),
        .blank(blank), .hsync_n(hsync_n), .vsync_n(vsync_n), .rgb(9'd0),
        .packet_enable(packet_enable), .field_end(field_end),
        .island_preamble(island_preamble), .island_guard(island_guard),
        .island_period(island_period), .island_first(island_first),
        .video_preamble(video_preamble), .video_guard(video_guard),
        .video_period(video_period), .line_start(line_start),
        .hsync_level(hsync_level), .vsync_level(vsync_level),
        .video(video), .locked(locked));

    // stage 1 describes the position of hcnt_q one cycle earlier
    reg [9:0] x1 = 10'd0, y1 = 10'd0;
    reg pe0 = 1'b0, fe0 = 1'b0;
    always @(posedge clock) begin
        x1 <= hcnt_q; y1 <= vcnt_q;
    end

    integer errors = 0, islands = 0, guards = 0, fields = 0, checked_lines = 0;
    integer locked_frames = 0;
    reg checking = 1'b0;
    reg [9:0] y_last = 10'd0;
    task fail(input [8*48-1:0] what);
        begin
            if (errors < 12)
                $display("FAIL %0s at x=%0d y=%0d frame=%0d", what, x1, y1, frame);
            errors = errors + 1;
        end
    endtask
    wire active_line1 = y1 >= VACTIVE;
    always @(posedge clock) begin
        if (frame >= 2) checking <= 1'b1;
        if (checking) begin
            if (island_preamble != (x1 >= 4 && x1 < 12)) fail("island preamble");
            if (island_guard != (x1 == 12 || x1 == 13 || x1 == 46 || x1 == 47)) fail("island guard");
            if (island_period != (x1 >= 14 && x1 < 46)) fail("island period");
            if (island_first != (x1 == 14)) fail("island first");
            if (video_preamble != (active_line1 && x1 >= HACTIVE - 10 && x1 < HACTIVE - 2)) fail("video preamble");
            if (video_guard != (active_line1 && x1 >= HACTIVE - 2 && x1 < HACTIVE)) fail("video guard");
            if (video_period != (active_line1 && x1 >= HACTIVE)) fail("video period");
            if ((island_period || island_guard || island_preamble) && (video_period || video_guard || video_preamble))
                fail("island overlaps video");
            if (hsync_level != !(x1 >= HSYNC_BEG && x1 <= HSYNC_END)) fail("hsync level");
            if (island_first) islands = islands + 1;
            if (video_guard && x1 == HACTIVE - 1) guards = guards + 1;
            if (x1 == 0) checked_lines = checked_lines + 1;
        end
    end
    // stage 0 strobes, against the outputs' own position (hcnt_q)
    always @(posedge clock) begin
        if (checking) begin
            if (packet_enable != (hcnt_q == 14)) begin
                if (errors < 12) $display("FAIL packet_enable at x=%0d y=%0d", hcnt_q, vcnt_q);
                errors = errors + 1;
            end
            if (field_end != (hcnt_q == HLAST && vcnt_q == VLAST)) begin
                if (errors < 12) $display("FAIL field_end at x=%0d y=%0d", hcnt_q, vcnt_q);
                errors = errors + 1;
            end
            if (field_end) fields = fields + 1;
        end
    end

    integer active_lines_expected = 0;
    initial begin
        repeat (20) @(posedge clock);
        reset = 1'b0;
        wait (frame == FRAMES);
        repeat (40) @(posedge clock);   // the outputs lag the counters; past this line's island
        if (!locked) begin $display("FAIL not locked at the end"); errors = errors + 1; end
        if (islands != checked_lines) begin
            $display("FAIL %0d islands on %0d lines", islands, checked_lines); errors = errors + 1;
        end
        if (guards != (FRAMES - 2) * (VLAST - VACTIVE + 1)) begin
            $display("FAIL %0d video guard bands, expected %0d", guards, (FRAMES - 2) * (VLAST - VACTIVE + 1));
            errors = errors + 1;
        end
        if (fields != FRAMES - 2) begin
            $display("FAIL %0d field ends, expected %0d", fields, FRAMES - 2); errors = errors + 1;
        end
        $display("video_60=%0d lines=%0d islands=%0d guards=%0d fields=%0d errors=%0d",
                 VIDEO_60, checked_lines, islands, guards, fields, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
`default_nettype wire
