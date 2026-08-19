"""Regress the ULA-qualified-stream to frame-buffer coordinate bridge."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl" / "video" / "nexttang_ula_capture.v"


class UlaCaptureTest(unittest.TestCase):
    def test_coordinates_and_frame_boundary(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, frame_sync = 0, pixel_valid = 0;
    reg [7:0] pixel = 0;
    wire frame_start, valid, error;
    wire [2:0] x;
    wire [1:0] y;
    wire [7:0] captured;
    integer expected_x = 0, expected_y = 0, count = 0;

    always #5 clock = ~clock;

    nexttang_ula_capture #(
        .FRAME_WIDTH(5), .FRAME_HEIGHT(3), .PIXEL_BITS(8)
    ) dut (
        .clock(clock), .reset(reset), .frame_sync(frame_sync),
        .pixel_valid(pixel_valid), .pixel(pixel),
        .capture_frame_start(frame_start), .capture_pixel_valid(valid),
        .capture_x(x), .capture_y(y), .capture_pixel(captured),
        .protocol_error(error)
    );

    always @(negedge clock) begin
        if (valid) begin
            if (x !== expected_x || y !== expected_y)
                $fatal(1, "coordinate mismatch got %0d,%0d expected %0d,%0d",
                       x, y, expected_x, expected_y);
            if (captured !== count[7:0])
                $fatal(1, "pixel mismatch got %0d expected %0d", captured, count);
            if (frame_start !== (count == 0))
                $fatal(1, "frame_start mismatch at pixel %0d", count);
            count = count + 1;
            if (expected_x == 4) begin
                expected_x = 0;
                expected_y = expected_y + 1;
            end else begin
                expected_x = expected_x + 1;
            end
        end
    end

    task send_frame;
        integer row, column;
        begin
            @(negedge clock); frame_sync = 1;
            @(negedge clock); frame_sync = 0;
            repeat (2) @(negedge clock);
            for (row = 0; row < 3; row = row + 1) begin
                for (column = 0; column < 5; column = column + 1) begin
                    pixel = (row * 5 + column);
                    pixel_valid = 1;
                    @(negedge clock);
                end
                pixel_valid = 0;
                repeat (3) @(negedge clock);
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clock);
        reset = 0;

        // A PLL can release the bridge in the middle of the native raster.
        // Pixels before the first frame marker are deliberately ignored and
        // must not poison the sticky protocol status.
        pixel_valid = 1;
        repeat (2) @(negedge clock);
        pixel_valid = 0;
        repeat (2) @(negedge clock);
        if (error) $fatal(1, "pre-frame pixels raised protocol_error");

        send_frame();
        repeat (3) @(negedge clock);
        if (count != 15) $fatal(1, "captured %0d pixels", count);
        if (error) $fatal(1, "protocol_error asserted for valid frame");
        $display("ULA_CAPTURE_PASS");
        $finish;
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "testbench"
            source = Path(directory) / "testbench.v"
            source.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-o", str(executable), str(RTL), str(source)],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run(
                ["vvp", str(executable)], cwd=REPO_ROOT,
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ULA_CAPTURE_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
