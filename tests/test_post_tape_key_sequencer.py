"""Behavioural regression for an optional key after tape playback."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SEQUENCER_RTL = (
    REPO_ROOT / "rtl" / "input" / "nexttang_post_tape_key_sequencer.v"
)


class PostTapeKeySequencerTests(unittest.TestCase):
    def test_presses_and_releases_configured_key_sequence_once(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg start = 0;
    wire [39:0] keys;
    wire finished;
    integer presses = 0;
    reg [39:0] previous_keys = 0;

    always #5 clock = ~clock;

    nexttang_post_tape_key_sequencer #(
        .CLOCK_HZ(1000),
        .START_DELAY_MS(2),
        .HOLD_MS(2),
        .GAP_MS(2),
        .KEY_ROW(1),
        .KEY_COLUMN(1),
        .SECOND_KEY_ENABLE(1),
        .SECOND_KEY_ROW(3),
        .SECOND_KEY_COLUMN(0)
    ) dut (
        .clock(clock),
        .reset(reset),
        .start(start),
        .keys(keys),
        .finished(finished)
    );

    always @(posedge clock) begin
        if (keys != 0 && previous_keys == 0) begin
            case (presses)
                0: if (keys != (40'b1 << (1 * 5 + 1)))
                       $fatal(1, "first configured key was not S");
                1: if (keys != (40'b1 << (3 * 5)))
                       $fatal(1, "second configured key was not 1");
                default: $fatal(1, "post-tape sequence repeated");
            endcase
            presses <= presses + 1;
        end
        previous_keys <= keys;
    end

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;
        repeat (3) @(posedge clock);
        if (keys != 0 || finished)
            $fatal(1, "key sequence started before tape finished");
        start = 1;
        repeat (20) begin
            @(posedge clock);
            if (finished) begin
                #1;
                if (presses != 2 || keys != 0)
                    $fatal(1, "post-tape key did not finish cleanly");
                repeat (5) @(posedge clock);
                if (presses != 2 || keys != 0)
                    $fatal(1, "post-tape key repeated while start stayed high");
                $display("PASS presses=%0d", presses);
                $finish;
            end
        end
        $fatal(1, "post-tape key sequence timed out");
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            testbench_path = root / "testbench.v"
            simulation = root / "simulation"
            testbench_path.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                [
                    "iverilog",
                    "-g2012",
                    "-o",
                    str(simulation),
                    str(SEQUENCER_RTL),
                    str(testbench_path),
                ],
                cwd=root,
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
                ["vvp", str(simulation)],
                cwd=root,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS presses=2", result.stdout)


if __name__ == "__main__":
    unittest.main()
