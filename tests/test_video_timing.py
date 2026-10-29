"""Behavioural test for the reusable raster timing generator."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
TIMING_RTL = REPO_ROOT / "rtl" / "video" / "nexttang_video_timing.v"


class VideoTimingTest(unittest.TestCase):
    def test_active_sync_and_frame_boundaries(self) -> None:
        testbench = r"""
`timescale 1ns/1ps

module testbench;
    reg pixel_clk = 0;
    reg reset = 1;
    wire hsync;
    wire vsync;
    wire data_enable;
    wire [3:0] horizontal_position;
    wire [2:0] vertical_position;
    integer sample_count = 0;
    reg sampling = 0;

    nexttang_video_timing #(
        .H_ACTIVE(4), .H_FRONT(1), .H_SYNC(2), .H_BACK(1),
        .V_ACTIVE(2), .V_FRONT(1), .V_SYNC(1), .V_BACK(1),
        .H_BITS(4), .V_BITS(3)
    ) dut (
        .pixel_clk(pixel_clk), .reset(reset),
        .hsync(hsync), .vsync(vsync), .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    always #1 pixel_clk = ~pixel_clk;

    always @(negedge pixel_clk) begin
        if (sampling) begin
            if (hsync !== (horizontal_position >= 5 &&
                           horizontal_position < 7))
                $fatal(1, "horizontal sync mismatch at %0d,%0d",
                       horizontal_position, vertical_position);
            if (vsync !== (vertical_position >= 3 &&
                           vertical_position < 4))
                $fatal(1, "vertical sync mismatch at %0d,%0d",
                       horizontal_position, vertical_position);
            if (data_enable !== (horizontal_position < 4 &&
                                 vertical_position < 2))
                $fatal(1, "data enable mismatch at %0d,%0d",
                       horizontal_position, vertical_position);
            if (horizontal_position !== sample_count % 8 ||
                vertical_position !== (sample_count / 8) % 5)
                $fatal(1, "raster order mismatch at sample %0d", sample_count);
            sample_count = sample_count + 1;
            if (sample_count == 80) begin
                $display("VIDEO_TIMING_PASS");
                $finish;
            end
        end
    end

    initial begin
        repeat (2) @(posedge pixel_clk);
        @(negedge pixel_clk);
        reset = 0;
        @(posedge pixel_clk);
        #0.1 sampling = 1;
    end

    initial begin
        #1000;
        $fatal(1, "video timing test timed out");
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.v"
            simulation_path = temporary_path / "simulation.vvp"
            testbench_path.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                [
                    "iverilog",
                    "-g2012",
                    "-Wall",
                    "-s",
                    "testbench",
                    "-o",
                    str(simulation_path),
                    str(TIMING_RTL),
                    str(testbench_path),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            simulation_result = subprocess.run(
                ["vvp", str(simulation_path)],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                simulation_result.returncode,
                0,
                simulation_result.stdout + simulation_result.stderr,
            )
            self.assertIn("VIDEO_TIMING_PASS", simulation_result.stdout)


    def test_alternate_front_porch_switches_only_between_frames(self) -> None:
        # H_FRONT 3 gives 10-pixel lines, H_FRONT_ALT 1 gives 8; five lines a
        # frame. alt_select rises during frame 0 and falls during frame 1, so
        # frame 1 alone must use the short line, with hsync moved to match.
        testbench = r"""
`timescale 1ns/1ps

module testbench;
    reg pixel_clk = 0;
    reg reset = 1;
    reg alt_select = 0;
    wire alt_active, hsync, vsync, data_enable;
    wire [3:0] horizontal_position;
    wire [2:0] vertical_position;

    nexttang_video_timing #(
        .H_ACTIVE(4), .H_FRONT(3), .H_SYNC(2), .H_BACK(1),
        .V_ACTIVE(2), .V_FRONT(1), .V_SYNC(1), .V_BACK(1),
        .H_BITS(4), .V_BITS(3), .H_FRONT_ALT(1)
    ) dut (
        .pixel_clk(pixel_clk), .reset(reset), .alt_select(alt_select),
        .alt_active(alt_active),
        .hsync(hsync), .vsync(vsync), .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    always #1 pixel_clk = ~pixel_clk;

    integer frame = -1, line_length = 0, frame_length = 0, samples = 0;
    integer expected_length;
    reg [3:0] previous_h = 0;
    reg sampling = 0;

    always @(negedge pixel_clk) if (sampling) begin
        expected_length = (frame == 1) ? 8 : 10;
        if (horizontal_position == 0 && vertical_position == 0) begin
            frame = frame + 1;
            if (frame == 0) alt_select = 1;    // during frame 0
        end
        if (frame == 1 && horizontal_position == 2 && vertical_position == 2)
            alt_select = 0;                    // during frame 1
        if (frame >= 0) begin
            if (horizontal_position == 0 && samples > 0 && previous_h != expected_length - 1 &&
                !(vertical_position == 0 && previous_h == ((frame == 2) ? 7 : 9)))
                $fatal(1, "frame %0d line ended at %0d", frame, previous_h);
            if (hsync !== (horizontal_position >= 4 + (expected_length - 7) &&
                           horizontal_position < 6 + (expected_length - 7)))
                $fatal(1, "frame %0d hsync wrong at %0d", frame, horizontal_position);
            if (horizontal_position >= expected_length)
                $fatal(1, "frame %0d position %0d past the line", frame, horizontal_position);
            samples = samples + 1;
        end
        previous_h = horizontal_position;
        if (frame == 3) begin
            $display("VIDEO_TIMING_ALT_PASS");
            $finish;
        end
    end

    initial begin
        repeat (2) @(posedge pixel_clk);
        @(negedge pixel_clk);
        reset = 0;
        @(posedge pixel_clk);
        #0.1 sampling = 1;
    end

    initial begin
        #2000;
        $fatal(1, "alternate timing test timed out");
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.v"
            simulation_path = temporary_path / "simulation.vvp"
            testbench_path.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(simulation_path), str(TIMING_RTL), str(testbench_path)],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            simulation_result = subprocess.run(
                ["vvp", str(simulation_path)],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertEqual(simulation_result.returncode, 0,
                             simulation_result.stdout + simulation_result.stderr)
            self.assertIn("VIDEO_TIMING_ALT_PASS", simulation_result.stdout)

if __name__ == "__main__":
    unittest.main()
