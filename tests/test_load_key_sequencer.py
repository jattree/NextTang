"""Behavioural regression for the synthetic LOAD command."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SEQUENCER_RTL = (
    REPO_ROOT / "rtl" / "input" / "nexttang_load_key_sequencer.v"
)


class LoadKeySequencerTests(unittest.TestCase):
    def test_types_load_quotes_and_enter_before_start_signal(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    wire [39:0] keys;
    wire finished;
    integer presses = 0;
    reg [39:0] previous_keys = 0;

    always #5 clock = ~clock;

    nexttang_load_key_sequencer #(
        .CLOCK_HZ(1000), .START_DELAY_MS(2), .HOLD_MS(2), .GAP_MS(2)
    ) dut (.clock(clock), .reset(reset), .keys(keys), .finished(finished));

    always @(posedge clock) begin
        if (keys != 0 && previous_keys == 0) begin
            case (presses)
                0: if (keys != (40'b1 << (6 * 5 + 3)))
                       $fatal(1, "first key was not J");
                1, 2: if (keys != ((40'b1 << (5 * 5)) |
                                    (40'b1 << (7 * 5 + 1))))
                          $fatal(1, "quote chord was wrong");
                3: if (keys != (40'b1 << (6 * 5)))
                       $fatal(1, "final key was not ENTER");
            endcase
            presses <= presses + 1;
        end
        previous_keys <= keys;
    end

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;
        repeat (100) begin
            @(posedge clock);
            if (finished) begin
                #1;
                if (presses != 4 || keys != 0)
                    $fatal(1, "LOAD sequence did not finish cleanly");
                $display("PASS presses=%0d", presses);
                $finish;
            end
        end
        $fatal(1, "LOAD sequence timed out");
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
            self.assertIn("PASS presses=4", result.stdout)


if __name__ == "__main__":
    unittest.main()
