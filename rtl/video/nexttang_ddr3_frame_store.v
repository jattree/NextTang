// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// nexttang_framebuffer_scaler with its three frames held in DDR3 instead of
// block RAM.
//
// The frame handover is the scaler's: the source owns one of three frame
// banks, the HDMI side owns another, a completed frame may wait in the third,
// and banks change owner only through the publish/acknowledge toggles at
// frame boundaries. Only the storage moves.
//
// Each completed source line goes from a four-line ring in block RAM to DDR3,
// PIXELS_PER_BEAT pixels to a 32-byte beat. The HDMI side asks for each source
// line two lines before it shows it, and the line comes back from DDR3 into a
// second four-line ring that the output reads exactly as the scaler read its
// frame memory, with the same two-stage latency. A source line lasts two
// output lines, so a fetch has about four output lines (88 us at 720p60) to
// arrive. Writes have four source lines (256 us).
//
// The DDR3 side makes one transaction at a time and asks for each with
// controller_request, for an arbiter to grant by passing the controller's
// ready signals through. fetch_late is set for good if a line was asked for,
// or completed, before the previous one had been dealt with.

`default_nettype none

module nexttang_ddr3_frame_store #(
    parameter integer SOURCE_WIDTH = 360,
    parameter integer SOURCE_HEIGHT = 288,
    parameter integer SCALE = 2,
    parameter integer OUTPUT_WIDTH = 1280,
    parameter integer OUTPUT_HEIGHT = 720,
    parameter integer PIXEL_BITS = 8,
    parameter integer ALT_SOURCE_HEIGHT = 0,
    // The first 32-byte beat of the store. The default sits at 2 MiB, just
    // above the Next's memory.
    parameter integer BASE_BEAT = 'h10000
) (
    input  wire                              source_clock,
    input  wire                              source_reset,
    input  wire                              source_frame_start,
    input  wire                              source_short,
    input  wire                              source_pixel_valid,
    input  wire [$clog2(SOURCE_WIDTH)-1:0]   source_x,
    input  wire [$clog2(SOURCE_HEIGHT)-1:0]  source_y,
    input  wire [PIXEL_BITS-1:0]             source_pixel,
    output reg                               source_overrun,

    input  wire                              output_clock,
    input  wire                              output_reset,
    input  wire                              output_frame_start,
    input  wire                              output_hsync,
    input  wire                              output_vsync,
    input  wire                              output_data_enable,
    input  wire [$clog2(OUTPUT_WIDTH)-1:0]   output_x,
    input  wire [$clog2(OUTPUT_HEIGHT)-1:0]  output_y,
    output reg                               scaled_hsync,
    output reg                               scaled_vsync,
    output reg                               scaled_data_enable,
    output reg  [PIXEL_BITS-1:0]             scaled_pixel,
    output reg                               output_frame_valid,

    input  wire                              memory_clock,
    input  wire                              memory_reset,
    input  wire                              memory_available,
    output wire                              controller_request,
    input  wire                              controller_command_ready,
    output wire [2:0]                        controller_command,
    output wire                              controller_command_enable,
    output wire [28:0]                       controller_address,
    input  wire                              controller_write_data_ready,
    output wire [255:0]                      controller_write_data,
    output wire                              controller_write_data_enable,
    output wire                              controller_write_data_end,
    output wire [31:0]                       controller_write_data_mask,
    input  wire [255:0]                      controller_read_data,
    input  wire                              controller_read_data_valid,
    output wire                              controller_burst,
    output reg                               fetch_late
);
    localparam integer SCALED_WIDTH = SOURCE_WIDTH * SCALE;
    localparam integer SCALED_HEIGHT = SOURCE_HEIGHT * SCALE;
    localparam integer LEFT = (OUTPUT_WIDTH - SCALED_WIDTH) / 2;
    localparam integer TOP = (OUTPUT_HEIGHT - SCALED_HEIGHT) / 2;
    localparam integer SHORT_HEIGHT = ALT_SOURCE_HEIGHT == 0 ? SOURCE_HEIGHT : ALT_SOURCE_HEIGHT;
    localparam integer SCALED_HEIGHT_SHORT = SHORT_HEIGHT * SCALE;
    localparam integer TOP_SHORT = (OUTPUT_HEIGHT - SCALED_HEIGHT_SHORT) / 2;

    localparam integer PIXELS_PER_BEAT = 256 / PIXEL_BITS;
    localparam integer PACKED_BITS = PIXELS_PER_BEAT * PIXEL_BITS;
    localparam integer BEATS_PER_LINE = (SOURCE_WIDTH + PIXELS_PER_BEAT - 1) / PIXELS_PER_BEAT;
    localparam integer BEAT_BITS = BEATS_PER_LINE > 1 ? $clog2(BEATS_PER_LINE) : 1;
    localparam integer LINE_BITS = $clog2(SOURCE_HEIGHT);
    // Line positions run to the end of the last beat; the rest of the last
    // beat is never shown.
    localparam integer X_BITS = $clog2(BEATS_PER_LINE * PIXELS_PER_BEAT);
    localparam integer SLOT_PIXELS = 1 << X_BITS;
    localparam integer Y_BITS = $clog2(OUTPUT_HEIGHT);

    initial begin
        if (SCALE != 2)
            $error("nexttang_ddr3_frame_store: each source line must last two output lines");
        if (SCALED_WIDTH > OUTPUT_WIDTH || SCALED_HEIGHT > OUTPUT_HEIGHT)
            $error("nexttang_ddr3_frame_store: scaled raster does not fit output");
        // Lines 0 and 1 are asked for four and two lines above the picture.
        if (TOP < 6 || TOP_SHORT < 6)
            $error("nexttang_ddr3_frame_store: the picture needs six lines above it");
    end

    // Four source lines on each side, by line number modulo four.
    reg [PIXEL_BITS-1:0] write_ring [0:4*SLOT_PIXELS-1];
    reg [PIXEL_BITS-1:0] read_ring [0:4*SLOT_PIXELS-1];

    function automatic [1:0] remaining_bank;
        input [1:0] first;
        input [1:0] second;
        begin
            remaining_bank = 2'd3 - first - second;
        end
    endfunction

    // --------------------------------------------------------------- producer
    reg [1:0] write_bank;
    reg [1:0] published_bank;
    reg       publish_toggle;
    reg       capture_active;
    reg       frame_short;
    reg       published_short;

    reg       acknowledge_meta;
    reg       acknowledge_sync;
    reg [1:0] read_bank_meta;
    reg [1:0] read_bank_sync;

    // Each completed line, for the DDR3 side. The bank and line stay put until
    // the next line completes, 64 us later.
    reg                 line_done_toggle;
    reg [1:0]           line_done_bank;
    reg [LINE_BITS-1:0] line_done_y;

    wire source_line_end = source_x == SOURCE_WIDTH - 1;
    wire source_last_pixel = source_line_end &&
                             source_y == (frame_short ? SHORT_HEIGHT - 1 : SOURCE_HEIGHT - 1);
    wire source_write = source_pixel_valid && (capture_active || source_frame_start);
    wire [X_BITS-1:0] source_ring_x = source_x;

    always @(posedge source_clock) begin
        if (source_write)
            write_ring[{source_y[1:0], source_ring_x}] <= source_pixel;
    end

    always @(posedge source_clock) begin
        if (source_reset) begin
            acknowledge_meta <= 1'b0;
            acknowledge_sync <= 1'b0;
            read_bank_meta <= 2'd0;
            read_bank_sync <= 2'd0;
        end else begin
            acknowledge_meta <= acknowledge_toggle;
            acknowledge_sync <= acknowledge_meta;
            read_bank_meta <= read_bank;
            read_bank_sync <= read_bank_meta;
        end
    end

    always @(posedge source_clock) begin
        if (source_reset) begin
            write_bank <= 2'd1;
            published_bank <= 2'd1;
            publish_toggle <= 1'b0;
            capture_active <= 1'b0;
            source_overrun <= 1'b0;
            frame_short <= 1'b0;
            published_short <= 1'b0;
            line_done_toggle <= 1'b0;
            line_done_bank <= 2'd0;
            line_done_y <= {LINE_BITS{1'b0}};
        end else begin
            if (source_frame_start) begin
                capture_active <= 1'b1;
                frame_short <= ALT_SOURCE_HEIGHT != 0 && source_short;
            end

            if (source_write && source_line_end) begin
                line_done_toggle <= !line_done_toggle;
                line_done_bank <= write_bank;
                line_done_y <= source_y;
            end

            if (source_write && source_last_pixel) begin
                capture_active <= 1'b0;
                if (acknowledge_sync == publish_toggle &&
                        read_bank_sync != write_bank) begin
                    published_bank <= write_bank;
                    published_short <= frame_short;
                    publish_toggle <= !publish_toggle;
                    write_bank <= remaining_bank(write_bank, read_bank_sync);
                end else begin
                    // The HDMI side did not consume the previous publication
                    // within one source frame.  Drop this completed frame and
                    // reuse its bank; never write into the reader's bank.
                    source_overrun <= 1'b1;
                end
            end
        end
    end

    // --------------------------------------------------------------- consumer
    reg       publish_meta;
    reg       publish_sync;
    reg [1:0] published_bank_meta;
    reg [1:0] published_bank_sync;
    reg [1:0] read_bank;
    reg       acknowledge_toggle;
    reg       published_short_meta;
    reg       published_short_sync;
    reg       read_short;

    // Each source line the picture is about to need, for the DDR3 side. The
    // bank and line stay put for two output lines.
    reg                 fetch_toggle;
    reg [1:0]           fetch_bank;
    reg [LINE_BITS-1:0] fetch_y;

    wire [Y_BITS-1:0] picture_top =
        read_short ? TOP_SHORT[Y_BITS-1:0] : TOP[Y_BITS-1:0];
    wire [Y_BITS:0] picture_bottom =
        read_short ? TOP_SHORT + SCALED_HEIGHT_SHORT : TOP + SCALED_HEIGHT;
    wire [LINE_BITS:0] picture_lines =
        read_short ? SHORT_HEIGHT[LINE_BITS:0] : SOURCE_HEIGHT[LINE_BITS:0];
    wire inside_picture = output_data_enable &&
                          output_x >= LEFT && output_x < LEFT + SCALED_WIDTH &&
                          output_y >= picture_top && output_y < picture_bottom;
    wire [30:0] mapped_x_calculation =
        (output_x - LEFT) / SCALE;
    wire [30:0] mapped_y_calculation =
        (output_y - picture_top) / SCALE;
    wire [X_BITS-1:0] mapped_x = mapped_x_calculation[X_BITS-1:0];
    wire [1:0] mapped_slot = mapped_y_calculation[1:0];
    wire [X_BITS+1:0] output_address = {mapped_slot, mapped_x};

    // At the start of every second output line from four above the picture,
    // ask for the source line two below the one being shown.
    wire [Y_BITS+1:0] lead_line = output_y + 4 - picture_top;
    wire [Y_BITS:0] wanted_line = lead_line[Y_BITS+1:1];
    wire fetch_now = output_frame_valid && output_x == 0 &&
                     !lead_line[Y_BITS+1] && !lead_line[0] &&
                     wanted_line < picture_lines;

    reg [X_BITS+1:0] output_address_q;
    reg inside_picture_q,output_hsync_q,output_vsync_q,output_data_enable_q;

    always @(posedge output_clock) begin
        if (output_reset) begin
            publish_meta <= 1'b0;
            publish_sync <= 1'b0;
            published_bank_meta <= 2'd1;
            published_bank_sync <= 2'd1;
            published_short_meta <= 1'b0;
            published_short_sync <= 1'b0;
        end else begin
            publish_meta <= publish_toggle;
            publish_sync <= publish_meta;
            published_bank_meta <= published_bank;
            published_bank_sync <= published_bank_meta;
            published_short_meta <= published_short;
            published_short_sync <= published_short_meta;
        end
    end

    always @(posedge output_clock) begin
        if (output_reset) begin
            read_bank <= 2'd0;
            read_short <= 1'b0;
            acknowledge_toggle <= 1'b0;
            output_frame_valid <= 1'b0;
            fetch_toggle <= 1'b0;
            fetch_bank <= 2'd0;
            fetch_y <= {LINE_BITS{1'b0}};
            scaled_hsync <= 1'b0;
            scaled_vsync <= 1'b0;
            scaled_data_enable <= 1'b0;
            scaled_pixel <= {PIXEL_BITS{1'b0}};
            output_address_q <= {(X_BITS+2){1'b0}};
            inside_picture_q <= 1'b0;output_hsync_q <= 1'b0;
            output_vsync_q <= 1'b0;output_data_enable_q <= 1'b0;
        end else begin
            if (output_frame_start && publish_sync != acknowledge_toggle) begin
                read_bank <= published_bank_sync;
                read_short <= published_short_sync;
                acknowledge_toggle <= publish_sync;
                output_frame_valid <= 1'b1;
            end

            if (fetch_now) begin
                fetch_toggle <= !fetch_toggle;
                fetch_bank <= read_bank;
                fetch_y <= wanted_line[LINE_BITS-1:0];
            end

            output_address_q <= output_address;inside_picture_q <= inside_picture;
            output_hsync_q <= output_hsync;output_vsync_q <= output_vsync;
            output_data_enable_q <= output_data_enable;
            scaled_hsync <= output_hsync_q;
            scaled_vsync <= output_vsync_q;
            scaled_data_enable <= output_data_enable_q;
            if (inside_picture_q && output_frame_valid)
                scaled_pixel <= read_ring[output_address_q];
            else
                scaled_pixel <= {PIXEL_BITS{1'b0}};
        end
    end

    // ----------------------------------------------------------------- DDR3
    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_PACK = 3'd1;
    localparam [2:0] STATE_WRITE = 3'd2;
    localparam [2:0] STATE_READ_COMMAND = 3'd3;
    localparam [2:0] STATE_READ_RESPONSE = 3'd4;
    localparam [2:0] STATE_UNPACK = 3'd5;

    // Toggles cross on two flops; the third stage marks the edge, by which
    // time the bank and line beside them have been still for two cycles.
    reg [2:0] line_done_meta;
    reg [2:0] fetch_meta;
    reg       write_pending;
    reg       fetch_pending;
    reg [1:0]           write_job_bank;
    reg [LINE_BITS-1:0] write_job_y;
    reg [1:0]           fetch_job_bank;
    reg [LINE_BITS-1:0] fetch_job_y;

    reg [2:0]           state;
    reg                 job_write;
    reg [1:0]           job_bank;
    reg [LINE_BITS-1:0] job_y;
    reg [BEAT_BITS-1:0] beat;
    reg [X_BITS:0]      pixel;          // position in the line being moved
    reg [X_BITS:0]      pixel_end;      // one past the current beat's pixels
    reg                 ring_valid;     // write_ring data arrives a cycle late
    reg [PIXEL_BITS-1:0] ring_data;
    reg [PACKED_BITS-1:0] beat_data;

    wire line_done_edge = line_done_meta[2] != line_done_meta[1];
    wire fetch_edge = fetch_meta[2] != fetch_meta[1];
    wire write_pair_ready = controller_command_ready && controller_write_data_ready;
    wire last_beat = beat == BEATS_PER_LINE - 1;

    // Beat address: BASE_BEAT + {bank, line, beat}.
    wire [25:0] beat_index = BASE_BEAT +
        {{(24-LINE_BITS-BEAT_BITS){1'b0}}, job_bank, job_y, beat};

    assign controller_request = state == STATE_WRITE || state == STATE_READ_COMMAND;
    assign controller_command = job_write ? 3'b000 : 3'b001;
    assign controller_command_enable =
        (state == STATE_WRITE && write_pair_ready) ||
        state == STATE_READ_COMMAND;
    assign controller_address = {beat_index, 3'b0};
    assign controller_write_data = {{(256-PACKED_BITS){1'b0}}, beat_data};
    assign controller_write_data_enable = state == STATE_WRITE && write_pair_ready;
    assign controller_write_data_end = 1'b1;
    assign controller_write_data_mask = 32'b0;
    assign controller_burst = 1'b0;

    always @(posedge memory_clock) begin
        ring_data <= write_ring[{job_y[1:0], pixel[X_BITS-1:0]}];
        if (state == STATE_UNPACK)
            read_ring[{job_y[1:0], pixel[X_BITS-1:0]}] <= beat_data[PIXEL_BITS-1:0];
    end

    always @(posedge memory_clock) begin
        if (memory_reset) begin
            line_done_meta <= 3'b0;
            fetch_meta <= 3'b0;
            write_pending <= 1'b0;
            fetch_pending <= 1'b0;
            write_job_bank <= 2'd0;
            write_job_y <= {LINE_BITS{1'b0}};
            fetch_job_bank <= 2'd0;
            fetch_job_y <= {LINE_BITS{1'b0}};
            state <= STATE_IDLE;
            job_write <= 1'b0;
            job_bank <= 2'd0;
            job_y <= {LINE_BITS{1'b0}};
            beat <= {BEAT_BITS{1'b0}};
            pixel <= {(X_BITS+1){1'b0}};
            pixel_end <= {(X_BITS+1){1'b0}};
            ring_valid <= 1'b0;
            beat_data <= {PACKED_BITS{1'b0}};
            fetch_late <= 1'b0;
        end else begin
            line_done_meta <= {line_done_meta[1:0], line_done_toggle};
            fetch_meta <= {fetch_meta[1:0], fetch_toggle};

            // Without calibrated memory the requests are dropped; the picture
            // is black until it is.
            if (line_done_edge && memory_available) begin
                write_pending <= 1'b1;
                write_job_bank <= line_done_bank;
                write_job_y <= line_done_y;
                if (write_pending)
                    fetch_late <= 1'b1;
            end
            if (fetch_edge && memory_available) begin
                fetch_pending <= 1'b1;
                fetch_job_bank <= fetch_bank;
                fetch_job_y <= fetch_y;
                if (fetch_pending)
                    fetch_late <= 1'b1;
            end

            ring_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    beat <= {BEAT_BITS{1'b0}};
                    pixel <= {(X_BITS+1){1'b0}};
                    pixel_end <= PIXELS_PER_BEAT;
                    // A fetch has the closer deadline.
                    if (fetch_pending && !fetch_edge) begin
                        fetch_pending <= 1'b0;
                        job_write <= 1'b0;
                        job_bank <= fetch_job_bank;
                        job_y <= fetch_job_y;
                        state <= STATE_READ_COMMAND;
                    end else if (write_pending && !line_done_edge) begin
                        write_pending <= 1'b0;
                        job_write <= 1'b1;
                        job_bank <= write_job_bank;
                        job_y <= write_job_y;
                        state <= STATE_PACK;
                    end
                end

                STATE_PACK: begin
                    // Address one pixel a cycle; each arrives a cycle later
                    // and shifts in from the top, so pixel 0 ends at the
                    // bottom of the beat.
                    if (pixel != pixel_end) begin
                        pixel <= pixel + 1'b1;
                        ring_valid <= 1'b1;
                    end
                    if (ring_valid)
                        beat_data <= {ring_data, beat_data[PACKED_BITS-1:PIXEL_BITS]};
                    if (pixel == pixel_end && !ring_valid)
                        state <= STATE_WRITE;
                end

                STATE_WRITE: begin
                    if (write_pair_ready) begin
                        beat <= beat + 1'b1;
                        pixel_end <= pixel_end + PIXELS_PER_BEAT;
                        state <= last_beat ? STATE_IDLE : STATE_PACK;
                    end
                end

                STATE_READ_COMMAND: begin
                    if (controller_command_ready)
                        state <= STATE_READ_RESPONSE;
                end

                STATE_READ_RESPONSE: begin
                    if (controller_read_data_valid) begin
                        beat_data <= controller_read_data[PACKED_BITS-1:0];
                        state <= STATE_UNPACK;
                    end
                end

                STATE_UNPACK: begin
                    // One pixel a cycle into the read ring, from the bottom.
                    beat_data <= beat_data >> PIXEL_BITS;
                    pixel <= pixel + 1'b1;
                    if (pixel == pixel_end - 1'b1) begin
                        beat <= beat + 1'b1;
                        pixel_end <= pixel_end + PIXELS_PER_BEAT;
                        state <= last_beat ? STATE_IDLE : STATE_READ_COMMAND;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
