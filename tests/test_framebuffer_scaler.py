"""The ULA raster must cross into HDMI without tearing or sampling its clock."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SCALER_RTL = REPO_ROOT / "rtl" / "video" / "nexttang_framebuffer_scaler.v"


def run_testbench(testbench: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        testbench_path = path / "testbench.v"
        simulation_path = path / "simulation.vvp"
        testbench_path.write_text(testbench, encoding="utf-8")
        compiled = subprocess.run(
            [
                "iverilog", "-g2012", "-Wall", "-s", "testbench",
                "-o", str(simulation_path), str(SCALER_RTL), str(testbench_path),
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(
            ["vvp", str(simulation_path)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    localparam integer SW = 4;
    localparam integer SH = 3;
    localparam integer OW = 12;
    localparam integer OH = 8;

    reg source_clock = 0;
    reg output_clock = 0;
    reg source_reset = 1;
    reg output_reset = 1;
    reg source_frame_start = 0;
    reg source_pixel_valid = 0;
    reg [1:0] source_x = 0;
    reg [1:0] source_y = 0;
    reg [7:0] source_pixel = 0;
    wire source_overrun;

    reg output_frame_start = 0;
    reg output_hsync = 0;
    reg output_vsync = 0;
    reg output_data_enable = 1;
    reg [3:0] output_x = 0;
    reg [2:0] output_y = 0;
    wire scaled_hsync;
    wire scaled_vsync;
    wire scaled_data_enable;
    wire [7:0] scaled_pixel;
    wire output_frame_valid;

    always #7 source_clock = ~source_clock;
    always #5 output_clock = ~output_clock;

    nexttang_framebuffer_scaler #(
        .SOURCE_WIDTH(SW), .SOURCE_HEIGHT(SH), .SCALE(2),
        .OUTPUT_WIDTH(OW), .OUTPUT_HEIGHT(OH), .PIXEL_BITS(8)
    ) dut (
        .source_clock(source_clock), .source_reset(source_reset),
        .source_frame_start(source_frame_start),
        .source_pixel_valid(source_pixel_valid),
        .source_x(source_x), .source_y(source_y), .source_pixel(source_pixel),
        .source_overrun(source_overrun),
        .output_clock(output_clock), .output_reset(output_reset),
        .output_frame_start(output_frame_start),
        .output_hsync(output_hsync), .output_vsync(output_vsync),
        .output_data_enable(output_data_enable),
        .output_x(output_x), .output_y(output_y),
        .scaled_hsync(scaled_hsync), .scaled_vsync(scaled_vsync),
        .scaled_data_enable(scaled_data_enable), .scaled_pixel(scaled_pixel),
        .output_frame_valid(output_frame_valid)
    );

    task send_frame;
        input [7:0] base;
        integer x;
        integer y;
        begin
            for (y = 0; y < SH; y = y + 1) begin
                for (x = 0; x < SW; x = x + 1) begin
                    @(negedge source_clock);
                    source_x = x[1:0];
                    source_y = y[1:0];
                    source_pixel = base + y * SW + x;
                    source_frame_start = x == 0 && y == 0;
                    source_pixel_valid = 1;
                end
            end
            @(negedge source_clock);
            source_frame_start = 0;
            source_pixel_valid = 0;
        end
    endtask

    task output_boundary;
        begin
            @(negedge output_clock);
            output_x = 0;
            output_y = 0;
            output_frame_start = 1;
            @(negedge output_clock);
            output_frame_start = 0;
        end
    endtask

    task expect_pixel;
        input [3:0] x;
        input [2:0] y;
        input [7:0] expected;
        begin
            @(negedge output_clock);
            output_x = x;
            output_y = y;
            output_data_enable = 1;
            @(posedge output_clock); #1;
            if (scaled_pixel !== expected)
                $fatal(1, "pixel (%0d,%0d) was %02x, expected %02x", x, y,
                       scaled_pixel, expected);
            if (!scaled_data_enable)
                $fatal(1, "data enable did not stay aligned with the pixel");
        end
    endtask

    initial begin
        repeat (3) @(posedge source_clock);
        source_reset = 0;
        output_reset = 0;

        // First complete source frame becomes visible only at an HDMI frame
        // boundary.  The 4x3 input is doubled and centred in 12x8.
        send_frame(8'h10);
        repeat (5) @(posedge output_clock);
        if (output_frame_valid)
            $fatal(1, "reader switched banks before an output frame boundary");
        output_boundary();
        expect_pixel(2, 1, 8'h10);
        expect_pixel(3, 1, 8'h10);
        expect_pixel(4, 1, 8'h11);
        expect_pixel(9, 6, 8'h1b);
        expect_pixel(1, 1, 8'h00);

        // Writing the next frame must not alter the bank currently being read.
        send_frame(8'h40);
        repeat (5) @(posedge output_clock);
        expect_pixel(2, 1, 8'h10);
        output_boundary();
        expect_pixel(2, 1, 8'h40);
        expect_pixel(9, 6, 8'h4b);

        // Control information is registered on the same edge as its pixel.
        @(negedge output_clock);
        output_x = 2; output_y = 1;
        output_hsync = 1; output_vsync = 1; output_data_enable = 0;
        @(posedge output_clock); #1;
        if (!scaled_hsync || !scaled_vsync || scaled_data_enable)
            $fatal(1, "HDMI control signals were not aligned with scaled output");
        if (scaled_pixel !== 8'h00)
            $fatal(1, "blanking emitted a stored pixel");

        if (source_overrun)
            $fatal(1, "normal 50-to-60 Hz handoff reported an overrun");
        $display("FRAMEBUFFER_SCALER_PASS");
        $finish;
    end
endmodule
"""


class FramebufferScalerTest(unittest.TestCase):
    def test_frames_cross_clocks_only_at_output_boundaries(self) -> None:
        self.assertIn("FRAMEBUFFER_SCALER_PASS", run_testbench(TESTBENCH))


if __name__ == "__main__":
    unittest.main()
