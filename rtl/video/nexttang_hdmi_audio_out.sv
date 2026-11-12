// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// hdmi_frame's picture as HDMI with sound: the TMDS symbols for its three
// channels, with audio, AVI and audio InfoFrames in a data island on every
// line.
//
// The frame (and so the picture's place and timing) stays hdmi_frame's;
// nexttang_hdmi_island_timing finds the island and guard band positions in it.
// The packets come from the hdl-util transmitter's own modules
// (rtl/video/hdmi/, MIT): packet_picker chooses audio clock regeneration,
// audio sample or InfoFrame packets, packet_assembler adds the ECC, and
// tmds_channel encodes video, control, TERC4 and guard bands.
//
// Latency: three pixel clocks from hdmi_frame's outputs to the symbols
// (island timing, the mode register here, tmds_channel), the same for every
// channel and every signal.


module nexttang_hdmi_audio_out #(
    parameter real VIDEO_RATE = 27.0E6,      // the pixel clock
    parameter int  AUDIO_RATE = 48000
) (
    input  logic        clock,                // pixel clock
    input  logic        reset,
    input  logic        video_60,             // 480p60 (VIC 2) instead of 576p50 (VIC 17)

    input  logic [9:0]  hactive,
    input  logic [9:0]  hsync_beg,
    input  logic [9:0]  hlast,
    input  logic [9:0]  vactive,
    input  logic [9:0]  vsync_end,
    input  logic [9:0]  vlast,

    input  logic        blank,
    input  logic        hsync_n,
    input  logic        vsync_n,
    input  logic [8:0]  rgb,

    input  logic        audio_ce,             // one sample, AUDIO_RATE per second
    input  logic [15:0] audio_left,
    input  logic [15:0] audio_right,

    output logic [9:0]  symbol_blue,
    output logic [9:0]  symbol_green,
    output logic [9:0]  symbol_red,
    output logic        islands_locked
);
    logic packet_enable, field_end;
    logic island_preamble, island_guard, island_period, island_first;
    logic video_preamble, video_guard, video_period, line_start;
    logic hsync_level, vsync_level;
    logic [8:0] video;

    nexttang_hdmi_island_timing timing (
        .clock(clock), .reset(reset),
        .hactive(hactive), .hsync_beg(hsync_beg), .hlast(hlast),
        .vactive(vactive), .vsync_end(vsync_end), .vlast(vlast),
        .blank(blank), .hsync_n(hsync_n), .vsync_n(vsync_n), .rgb(rgb),
        .packet_enable(packet_enable), .field_end(field_end),
        .island_preamble(island_preamble), .island_guard(island_guard),
        .island_period(island_period), .island_first(island_first),
        .video_preamble(video_preamble), .video_guard(video_guard),
        .video_period(video_period), .line_start(line_start),
        .hsync_level(hsync_level), .vsync_level(vsync_level),
        .video(video), .locked(islands_locked));

    logic [1:0] video_60_sync = 2'b00;
    always_ff @(posedge clock) video_60_sync <= {video_60_sync[0], video_60};

    logic [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = audio_left;
    assign audio_sample_word[1] = audio_right;

    logic [23:0] header;
    logic [55:0] sub [3:0];
    logic [4:0]  packet_pixel_counter;
    packet_picker #(
        .VIDEO_ID_CODE(17),
        .ALT_VIDEO_ID_CODE(2),
        .VIDEO_RATE(VIDEO_RATE),
        .IT_CONTENT(1'b1),
        .AUDIO_RATE(AUDIO_RATE),
        .AUDIO_BIT_WIDTH(16),
        .VENDOR_NAME({"NextTang"}),
        .PRODUCT_DESCRIPTION({"ZX Spectrum Next", 8'd0}),
        .SOURCE_DEVICE_INFORMATION(8'h00)
    ) packet_picker (
        .clk_pixel(clock), .audio_ce(audio_ce), .reset(reset),
        .alt_mode(video_60_sync[1]), .video_field_end(field_end),
        .packet_enable(packet_enable), .packet_pixel_counter(packet_pixel_counter),
        .audio_sample_word(audio_sample_word), .header(header), .sub(sub));

    // The packet counter restarts on every line, so a disturbed line cannot
    // leave the next island's packet out of step.
    logic [8:0] packet_data;
    packet_assembler packet_assembler (
        .clk_pixel(clock), .reset(reset || line_start), .data_island_period(island_period),
        .header(header), .sub(sub), .packet_data(packet_data), .counter(packet_pixel_counter));

    // mode: 0 control, 1 video, 2 video guard, 3 island, 4 island guard
    logic [2:0]  mode = 3'd0;
    logic [23:0] video_data = 24'd0;
    logic [5:0]  control_data = 6'd0;
    logic [11:0] island_data = 12'd0;
    always_ff @(posedge clock) begin
        mode <= island_guard ? 3'd4 : island_period ? 3'd3 : video_guard ? 3'd2
              : video_period ? 3'd1 : 3'd0;
        video_data <= {video[8:6], video[8:6], video[8:7],
                       video[5:3], video[5:3], video[5:4],
                       video[2:0], video[2:0], video[2:1]};
        // ctrl3 ctrl2 (channel 2), ctrl1 ctrl0 (channel 1), vsync hsync (channel 0)
        control_data <= {1'b0, island_preamble, 1'b0, video_preamble || island_preamble,
                         vsync_level, hsync_level};
        island_data[11:4] <= packet_data[8:1];
        island_data[3] <= !island_first;
        island_data[2] <= packet_data[0];
        island_data[1:0] <= {vsync_level, hsync_level};
    end

    tmds_channel #(.CN(0)) channel_blue (.clk_pixel(clock), .video_data(video_data[7:0]),
        .data_island_data(island_data[3:0]), .control_data(control_data[1:0]), .mode(mode), .tmds(symbol_blue));
    tmds_channel #(.CN(1)) channel_green (.clk_pixel(clock), .video_data(video_data[15:8]),
        .data_island_data(island_data[7:4]), .control_data(control_data[3:2]), .mode(mode), .tmds(symbol_green));
    tmds_channel #(.CN(2)) channel_red (.clk_pixel(clock), .video_data(video_data[23:16]),
        .data_island_data(island_data[11:8]), .control_data(control_data[5:4]), .mode(mode), .tmds(symbol_red));
endmodule

