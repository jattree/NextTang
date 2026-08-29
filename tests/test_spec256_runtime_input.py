"""Live keyboard and Kempston commands on the Spec256 runtime UART."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
INPUT_RTL = REPO_ROOT / "rtl" / "input" / "nexttang_spec256_runtime_input.v"


class Spec256RuntimeInputTests(unittest.TestCase):
    def test_framed_commands_update_and_clear_live_inputs(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg enable = 0;
    reg [7:0] byte_data = 0;
    reg byte_valid = 0;
    wire [39:0] keys;
    wire [4:0] joystick;

    always #5 clock = !clock;

    nexttang_spec256_runtime_input dut (
        .clock(clock), .reset(reset), .enable(enable),
        .byte_data(byte_data), .byte_valid(byte_valid),
        .keys(keys), .joystick(joystick)
    );

    task send_byte(input [7:0] value);
        begin
            @(negedge clock);
            byte_data = value;
            byte_valid = 1;
            @(negedge clock);
            byte_valid = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        // Commands received before a pack is ready cannot leak into a game.
        send_byte("K"); send_byte(18); send_byte(1);
        if (keys != 0 || joystick != 0)
            $fatal(1, "disabled input changed state");

        enable = 1;
        send_byte("K"); send_byte(18); send_byte(1);
        if (!keys[18]) $fatal(1, "key press was not applied");
        send_byte("K"); send_byte(19); send_byte(1);
        if (!keys[18] || !keys[19])
            $fatal(1, "second key did not preserve first");
        send_byte("K"); send_byte(18); send_byte(0);
        if (keys[18] || !keys[19])
            $fatal(1, "key release was not applied");

        // Kempston: bit 0 right, 1 left, 2 down, 3 up, 4 fire.
        send_byte("J"); send_byte(5'b11001);
        if (joystick != 5'b11001)
            $fatal(1, "joystick state was not applied: %b", joystick);

        reset = 1;
        @(posedge clock); #1;
        if (keys != 0 || joystick != 0)
            $fatal(1, "reset did not release live inputs");
        $finish;
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            testbench_path = root / "testbench.v"
            simulation = root / "simulation"
            testbench_path.write_text(testbench, encoding="ascii")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-o", simulation,
                 INPUT_RTL, testbench_path],
                cwd=root, check=False, capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run(
                ["vvp", simulation], cwd=root, check=False,
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
