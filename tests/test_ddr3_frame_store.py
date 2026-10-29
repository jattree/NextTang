"""The HDMI frame store must work from DDR3 while the CPU shares the memory.

The frame store, the arbiter and the CPU's posted-write adapter run together
against a controller model that takes 12 to 41 cycles to answer a read,
stalls for 26 cycles every 3.9 us as refresh does, drops its ready signals at
random, and makes writes visible up to 200 cycles after it accepts them. The
CPU side issues random reads and writes back to back the whole time and
checks every read.

The source sends 40-pixel frames at the real 7 MHz, 12 lines tall, then 8
lines tall (60 Hz), then 12 again, and the output scans at 75 MHz, switching
to a shorter frame for the short source frames as the board's 720p modes do.
Every pixel inside the picture must belong to one sent frame at the right
position, frames must appear in order and change only at frame boundaries,
and no line may be fetched late.

A second run makes every read take 700 cycles, longer than a fetch's four
output lines, and expects late fetches, so the checks are shown able to fail.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    REPO_ROOT / "rtl" / "video" / "nexttang_ddr3_frame_store.v",
    REPO_ROOT / "rtl" / "memory" / "nexttang_ddr3_ui_arbiter.v",
    REPO_ROOT / "rtl" / "memory" / "nexttang_gowin_ddr3_ui_adapter.v",
)


def testbench(read_latency_min: int, read_latency_spread: int) -> str:
    return (
        TESTBENCH
        .replace("@LATENCY_MIN@", str(read_latency_min))
        .replace("@LATENCY_SPREAD@", str(read_latency_spread))
    )


TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    localparam integer SW = 40, SH = 12, SHORT = 8;
    localparam integer SOURCE_TOTAL_X = 56, SOURCE_TOTAL_Y = 14, SHORT_TOTAL_Y = 10;
    localparam integer OW = 100, OH = 40, HT = 120, VT = 68, VT_SHORT = 48;
    localparam integer LEFT = 10, TOP = 8, TOP_SHORT = 12;
    localparam integer FRAMES = 16;
    localparam integer VISIBILITY = 200;

    reg source_clock = 0, output_clock = 0, memory_clock = 0;
    reg source_reset = 1, output_reset = 1, memory_reset = 1;
    always #71.4 source_clock = ~source_clock;
    always #6.667 output_clock = ~output_clock;
    always #5 memory_clock = ~memory_clock;

    // ------------------------------------------------------------- source
    reg source_frame_start = 0, source_short = 0, source_pixel_valid = 0;
    reg [5:0] source_x = 0;
    reg [3:0] source_y = 0;
    reg [8:0] source_pixel = 0;
    wire source_overrun;

    // ------------------------------------------------------------- output
    reg [6:0] output_x = 0;
    reg [5:0] output_y = 0;
    reg output_short = 0;
    wire output_data_enable = output_x < OW && output_y < OH;
    wire output_frame_start = output_x == 0 && output_y == 0;
    wire scaled_hsync, scaled_vsync, scaled_data_enable, output_frame_valid;
    wire [8:0] scaled_pixel;

    // ------------------------------------------------------------- memory
    wire video_request, video_command_ready, video_command_enable;
    wire [2:0] video_command;
    wire [28:0] video_address;
    wire video_write_data_ready, video_write_data_enable, video_write_data_end;
    wire [255:0] video_write_data;
    wire [31:0] video_write_data_mask;
    wire video_read_data_valid, video_burst, fetch_late;

    wire cpu_request, cpu_command_ready, cpu_command_enable;
    wire [2:0] cpu_command;
    wire [28:0] cpu_address;
    wire cpu_write_data_ready, cpu_write_data_enable, cpu_write_data_end;
    wire [255:0] cpu_write_data;
    wire [31:0] cpu_write_data_mask;
    wire cpu_read_data_valid, cpu_burst;

    reg controller_command_ready = 0, controller_write_data_ready = 0;
    wire [2:0] controller_command;
    wire controller_command_enable, controller_write_data_enable;
    wire controller_write_data_end, controller_burst;
    wire [28:0] controller_address;
    wire [255:0] controller_write_data;
    wire [31:0] controller_write_data_mask;
    reg [255:0] controller_read_data = 0;
    reg controller_read_data_valid = 0;

    nexttang_ddr3_frame_store #(
        .SOURCE_WIDTH(SW), .SOURCE_HEIGHT(SH), .SCALE(2),
        .OUTPUT_WIDTH(OW), .OUTPUT_HEIGHT(OH), .PIXEL_BITS(9),
        .ALT_SOURCE_HEIGHT(SHORT), .BASE_BEAT('h1000)
    ) dut (
        .source_clock(source_clock), .source_reset(source_reset),
        .source_frame_start(source_frame_start), .source_short(source_short),
        .source_pixel_valid(source_pixel_valid),
        .source_x(source_x), .source_y(source_y), .source_pixel(source_pixel),
        .source_overrun(source_overrun),
        .output_clock(output_clock), .output_reset(output_reset),
        .output_frame_start(output_frame_start),
        .output_hsync(1'b0), .output_vsync(1'b0),
        .output_data_enable(output_data_enable),
        .output_x(output_x), .output_y(output_y),
        .scaled_hsync(scaled_hsync), .scaled_vsync(scaled_vsync),
        .scaled_data_enable(scaled_data_enable), .scaled_pixel(scaled_pixel),
        .output_frame_valid(output_frame_valid),
        .memory_clock(memory_clock), .memory_reset(memory_reset),
        .memory_available(1'b1),
        .controller_request(video_request),
        .controller_command_ready(video_command_ready),
        .controller_command(video_command),
        .controller_command_enable(video_command_enable),
        .controller_address(video_address),
        .controller_write_data_ready(video_write_data_ready),
        .controller_write_data(video_write_data),
        .controller_write_data_enable(video_write_data_enable),
        .controller_write_data_end(video_write_data_end),
        .controller_write_data_mask(video_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(video_read_data_valid),
        .controller_burst(video_burst),
        .fetch_late(fetch_late)
    );

    reg line_request = 0, line_write = 0;
    wire line_ready, line_response_valid;
    reg [16:0] line_address = 0;
    reg [127:0] line_write_data = 0;
    reg [15:0] line_write_enable = 0;
    wire [127:0] line_read_data;

    nexttang_gowin_ddr3_ui_adapter #(
        .POSTED_WRITES(1), .PENDING_LINES(8)
    ) cpu (
        .clock(memory_clock), .reset(memory_reset),
        .line_request(line_request), .line_ready(line_ready),
        .line_write(line_write), .line_address(line_address),
        .line_write_data(line_write_data), .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid), .line_read_data(line_read_data),
        .controller_request(cpu_request),
        .controller_command_ready(cpu_command_ready),
        .controller_command(cpu_command),
        .controller_command_enable(cpu_command_enable),
        .controller_address(cpu_address),
        .controller_write_data_ready(cpu_write_data_ready),
        .controller_write_data(cpu_write_data),
        .controller_write_data_enable(cpu_write_data_enable),
        .controller_write_data_end(cpu_write_data_end),
        .controller_write_data_mask(cpu_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(cpu_read_data_valid),
        .controller_burst(cpu_burst)
    );

    nexttang_ddr3_ui_arbiter arbiter (
        .clock(memory_clock), .reset(memory_reset),
        .a_request(cpu_request), .a_command_ready(cpu_command_ready),
        .a_command(cpu_command), .a_command_enable(cpu_command_enable),
        .a_address(cpu_address), .a_write_data_ready(cpu_write_data_ready),
        .a_write_data(cpu_write_data), .a_write_data_enable(cpu_write_data_enable),
        .a_write_data_end(cpu_write_data_end), .a_write_data_mask(cpu_write_data_mask),
        .a_read_data_valid(cpu_read_data_valid), .a_burst(cpu_burst),
        .b_request(video_request), .b_command_ready(video_command_ready),
        .b_command(video_command), .b_command_enable(video_command_enable),
        .b_address(video_address), .b_write_data_ready(video_write_data_ready),
        .b_write_data(video_write_data), .b_write_data_enable(video_write_data_enable),
        .b_write_data_end(video_write_data_end), .b_write_data_mask(video_write_data_mask),
        .b_read_data_valid(video_read_data_valid), .b_burst(video_burst),
        .controller_command_ready(controller_command_ready),
        .controller_command(controller_command),
        .controller_command_enable(controller_command_enable),
        .controller_address(controller_address),
        .controller_write_data_ready(controller_write_data_ready),
        .controller_write_data(controller_write_data),
        .controller_write_data_enable(controller_write_data_enable),
        .controller_write_data_end(controller_write_data_end),
        .controller_write_data_mask(controller_write_data_mask),
        .controller_read_data_valid(controller_read_data_valid),
        .controller_burst(controller_burst)
    );

    // ---------------------------------------------------- controller model
    // 16K beats. Accepted writes land in order after up to VISIBILITY
    // cycles; a read sees memory as it is when accepted and answers after
    // LATENCY_MIN plus up to LATENCY_SPREAD cycles. Refresh holds both ready
    // signals low for 26 cycles in every 390, and they also drop at random.
    reg [255:0] memory [0:16383];
    reg [255:0] queued_data [0:255];
    reg [31:0]  queued_mask [0:255];
    reg [13:0]  queued_beat [0:255];
    integer     queued_due [0:255];
    integer queue_head = 0, queue_tail = 0, now = 0, read_due = -1;
    integer byte_index, protocol_errors = 0;
    reg [255:0] read_value;

    always @(posedge memory_clock) begin
        now <= now + 1;
        controller_read_data_valid <= 1'b0;
        while (queue_head != queue_tail && queued_due[queue_head % 256] <= now) begin
            for (byte_index = 0; byte_index < 32; byte_index = byte_index + 1)
                if (!queued_mask[queue_head % 256][byte_index])
                    memory[queued_beat[queue_head % 256]][byte_index*8 +: 8] =
                        queued_data[queue_head % 256][byte_index*8 +: 8];
            queue_head = queue_head + 1;
        end
        if (controller_command_enable && controller_command_ready) begin
            if (controller_command == 3'b000) begin
                if (!controller_write_data_enable || !controller_write_data_ready)
                    protocol_errors = protocol_errors + 1;
                queued_data[queue_tail % 256] = controller_write_data;
                queued_mask[queue_tail % 256] = controller_write_data_mask;
                queued_beat[queue_tail % 256] = controller_address[16:3];
                queued_due[queue_tail % 256] = now + 1 + ($urandom % VISIBILITY);
                if (queue_tail != queue_head &&
                        queued_due[queue_tail % 256] < queued_due[(queue_tail - 1) % 256])
                    queued_due[queue_tail % 256] = queued_due[(queue_tail - 1) % 256];
                queue_tail = queue_tail + 1;
            end else begin
                if (read_due >= 0)
                    protocol_errors = protocol_errors + 1;
                read_value = memory[controller_address[16:3]];
                read_due = now + @LATENCY_MIN@ + ($urandom % (@LATENCY_SPREAD@ + 1));
            end
        end else if (controller_write_data_enable) begin
            protocol_errors = protocol_errors + 1;
        end
        if (read_due == now) begin
            controller_read_data <= read_value;
            controller_read_data_valid <= 1'b1;
            read_due = -1;
        end
        controller_command_ready <= !memory_reset && (now % 390) >= 26 && ($urandom % 8) != 0;
        controller_write_data_ready <= !memory_reset && (now % 390) >= 26 && ($urandom % 8) != 0;
    end

    // ------------------------------------------------------- source frames
    reg [8:0] frame_base [0:FRAMES-1];
    reg       frame_short [0:FRAMES-1];
    integer frame, sx, sy, frame_lines, total_lines;
    reg sending = 1;

    initial begin
        for (frame = 0; frame < FRAMES; frame = frame + 1) begin
            frame_base[frame] = frame * 37 + 5;
            frame_short[frame] = frame >= 6 && frame < 11;
        end
    end

    initial begin
        repeat (5) @(posedge source_clock);
        source_reset = 0;
        for (frame = 0; frame < FRAMES; frame = frame + 1) begin
            frame_lines = frame_short[frame] ? SHORT : SH;
            total_lines = frame_short[frame] ? SHORT_TOTAL_Y : SOURCE_TOTAL_Y;
            for (sy = 0; sy < total_lines; sy = sy + 1)
                for (sx = 0; sx < SOURCE_TOTAL_X; sx = sx + 1) begin
                    @(negedge source_clock);
                    source_short = frame_short[frame];
                    source_x = sx < SW ? sx : 0;
                    source_y = sy < frame_lines ? sy : 0;
                    source_pixel_valid = sx < SW && sy < frame_lines;
                    source_frame_start = sx == 0 && sy == 0;
                    source_pixel = frame_base[frame] + sy * SW + sx;
                end
        end
        @(negedge source_clock);
        source_pixel_valid = 0;
        source_frame_start = 0;
        sending = 0;
    end

    // ------------------------------------------------------- output raster
    always @(posedge output_clock) begin
        if (output_reset) begin
            output_x <= 0;
            output_y <= 0;
        end else if (output_x == HT - 1) begin
            output_x <= 0;
            if (output_y == (output_short ? VT_SHORT : VT) - 1) begin
                output_y <= 0;
                // The board's HDMI mode follows the core's 50/60 Hz setting.
                output_short <= source_short;
            end else begin
                output_y <= output_y + 1;
            end
        end else begin
            output_x <= output_x + 1;
        end
    end

    // ------------------------------------------------------ picture checks
    reg [6:0] x_d1 = 0, x_d2 = 0;
    reg [5:0] y_d1 = 0, y_d2 = 0;
    reg de_d1 = 0, de_d2 = 0;
    integer shown = -1, frames_shown = 0, checked = 0, wrong = 0, black = 0;
    integer top, rows, mx, my, base, search;
    reg frame_open = 0;
    integer frame_base_seen = -1;

    always @(posedge output_clock) begin
        x_d1 <= output_x; x_d2 <= x_d1;
        y_d1 <= output_y; y_d2 <= y_d1;
        de_d1 <= output_data_enable; de_d2 <= de_d1;
    end

    always @(negedge output_clock) begin
        if (x_d2 == 0 && y_d2 == 0)
            frame_base_seen = -1;
        top = dut.read_short ? TOP_SHORT : TOP;
        rows = dut.read_short ? SHORT : SH;
        if (de_d2 && output_frame_valid) begin
            if (x_d2 >= LEFT && x_d2 < LEFT + 2 * SW &&
                    y_d2 >= top && y_d2 < top + 2 * rows) begin
                if (^scaled_pixel === 1'bx) begin
                    wrong = wrong + 1;
                    if (wrong < 5)
                        $display("unknown pixel at (%0d,%0d)", x_d2, y_d2);
                end
                mx = (x_d2 - LEFT) / 2;
                my = (y_d2 - top) / 2;
                base = (scaled_pixel - my * SW - mx) & 9'h1ff;
                checked = checked + 1;
                if (frame_base_seen < 0) begin
                    // A new picture: the next sent frame, or a later one if
                    // frames were dropped, with the height it was sent at.
                    frame_base_seen = base;
                    if (shown < 0 || frame_base[shown] != base) begin
                        search = shown + 1;
                        while (search < FRAMES &&
                                (frame_base[search] != base ||
                                 frame_short[search] != dut.read_short))
                            search = search + 1;
                        if (search >= FRAMES) begin
                            wrong = wrong + 1;
                            if (wrong < 5)
                                $display("unexpected picture base %0d at (%0d,%0d)", base, mx, my);
                        end else begin
                            shown = search;
                            frames_shown = frames_shown + 1;
                        end
                    end
                end else if (base != frame_base_seen) begin
                    wrong = wrong + 1;
                    if (wrong < 5)
                        $display("pixel (%0d,%0d) = %0d, frame base %0d", mx, my,
                                 scaled_pixel, frame_base_seen);
                end
            end else if (scaled_pixel !== 9'b0) begin
                black = black + 1;
            end
        end
    end

    // ------------------------------------------------------------ CPU side
    reg [127:0] expected [0:63];
    integer step, line, cpu_wrong = 0, cpu_steps = 0;
    integer read_cycles, read_count = 0, read_total = 0, read_longest = 0;
    reg [127:0] data;
    reg [15:0] enable;

    initial begin
        for (line = 0; line < 64; line = line + 1)
            expected[line] = 0;
        for (line = 0; line < 16384; line = line + 1)
            memory[line] = 0;
        repeat (5) @(posedge memory_clock);
        memory_reset = 0;
        output_reset = 0;
        while (sending) begin
            line = $urandom % 64;
            @(negedge memory_clock);
            while (!line_ready) @(negedge memory_clock);
            line_address = line;
            if ($urandom % 2) begin
                data = {$urandom, $urandom, $urandom, $urandom};
                enable = $urandom;
                line_write = 1;
                line_write_data = data;
                line_write_enable = enable;
                for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                    if (enable[byte_index])
                        expected[line][byte_index*8 +: 8] = data[byte_index*8 +: 8];
            end else begin
                line_write = 0;
            end
            line_request = 1;
            @(negedge memory_clock);
            line_request = 0;
            read_cycles = 1;
            while (!line_response_valid) begin
                @(negedge memory_clock);
                read_cycles = read_cycles + 1;
            end
            if (!line_write) begin
                if (line_read_data !== expected[line])
                    cpu_wrong = cpu_wrong + 1;
                read_count = read_count + 1;
                read_total = read_total + read_cycles;
                if (read_cycles > read_longest)
                    read_longest = read_cycles;
            end
            cpu_steps = cpu_steps + 1;
        end
        // Let the last frames reach the screen.
        repeat (3 * HT * VT) @(posedge output_clock);
        $display("CHECKED %0d WRONG %0d BLACK %0d FRAMES %0d LATE %0d OVERRUN %0d",
                 checked, wrong, black, frames_shown, fetch_late, source_overrun);
        $display("CPU_STEPS %0d CPU_WRONG %0d PROTOCOL %0d READ_MEAN %0d READ_LONGEST %0d",
                 cpu_steps, cpu_wrong, protocol_errors, read_total / read_count,
                 read_longest);
        $finish;
    end
endmodule
"""


def results(output: str) -> dict:
    values = {}
    for line in output.splitlines():
        words = line.split()
        if words and words[0] in ("CHECKED", "CPU_STEPS"):
            for name, value in zip(words[::2], words[1::2]):
                values[name] = int(value)
    return values


class Ddr3FrameStoreTest(unittest.TestCase):
    def test_frames_reach_hdmi_through_shared_ddr3(self) -> None:
        output = run_testbench(testbench(12, 29), *SOURCES)
        values = results(output)
        self.assertEqual(values["WRONG"], 0, output)
        self.assertEqual(values["BLACK"], 0, output)
        self.assertEqual(values["LATE"], 0, output)
        self.assertEqual(values["CPU_WRONG"], 0, output)
        self.assertEqual(values["PROTOCOL"], 0, output)
        # Sixteen frames sent; a frame may be dropped where the output
        # changes mode, as on the board, but the picture must keep moving.
        self.assertGreaterEqual(values["FRAMES"], 13, output)
        self.assertGreater(values["CHECKED"], 13 * 2 * 40 * 2 * 8, output)
        self.assertGreater(values["CPU_STEPS"], 2000, output)

    def test_slow_memory_is_reported_late(self) -> None:
        values = results(run_testbench(testbench(700, 0), *SOURCES))
        self.assertEqual(values["LATE"], 1)


if __name__ == "__main__":
    unittest.main()
