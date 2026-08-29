"""A normalized USB gamepad must appear as a real Kempston joystick."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class UsbGamepadKempstonTests(unittest.TestCase):
    def test_directions_and_any_face_button_map_to_port_1f(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg [1:0] device_type = 0;
    reg left = 0, right = 0, up = 0, down = 0;
    reg a = 0, b = 0, x = 0, y = 0;
    wire [4:0] joystick;

    nexttang_usb_gamepad_kempston dut (
        .device_type(device_type),
        .left(left), .right(right), .up(up), .down(down),
        .a(a), .b(b), .x(x), .y(y), .joystick(joystick)
    );

    initial begin
        right = 1; up = 1; b = 1; #1;
        if (joystick !== 5'b00000)
            $fatal(1, "non-game device leaked into Kempston port");

        device_type = 2'd3; #1;
        if (joystick !== 5'b11001)
            $fatal(1, "right/up/fire mapping was %05b", joystick);

        right = 0; up = 0; b = 0; left = 1; down = 1; y = 1; #1;
        if (joystick !== 5'b10110)
            $fatal(1, "left/down/fire mapping was %05b", joystick);
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            source = work / "testbench.v"
            output = work / "testbench.out"
            source.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                [
                    "iverilog", "-g2012", "-o", str(output),
                    str(REPO_ROOT / "rtl/input/nexttang_usb_gamepad_kempston.v"),
                    str(source),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stdout + compile_result.stderr,
            )
            result = subprocess.run(
                ["vvp", str(output)], check=False, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
