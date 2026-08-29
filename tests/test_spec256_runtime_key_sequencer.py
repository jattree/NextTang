"""Runtime launch-key sequencer driven by Spec256 pack metadata."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SEQUENCER_RTL = (
    REPO_ROOT / "rtl" / "input" / "nexttang_spec256_runtime_key_sequencer.v"
)


class Spec256RuntimeKeySequencerTests(unittest.TestCase):
    def test_loaded_two_key_sequence_is_pressed_once(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg start = 0;
    wire [39:0] keys;
    wire finished;
    integer saw_first = 0;
    integer saw_second = 0;
    integer cycles = 0;

    always #5 clock = !clock;

    nexttang_spec256_runtime_key_sequencer #(.CLOCK_HZ(1000)) dut (
        .clock(clock), .reset(reset), .start(start),
        .key_count(2), .key_0(18), .key_1(19), .key_2(0), .key_3(0),
        .start_delay_ms(2), .hold_ms(2), .gap_ms(3),
        .keys(keys), .finished(finished)
    );

    always @(posedge clock) begin
        cycles <= cycles + 1;
        if (keys[18]) saw_first <= saw_first + 1;
        if (keys[19]) saw_second <= saw_second + 1;
        if (keys & ~((40'b1 << 18) | (40'b1 << 19)))
            $fatal(1, "unexpected key mask %h", keys);
        if (cycles > 40)
            $fatal(1, "sequencer did not finish");
    end

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;
        start = 1;
        wait (finished);
        @(posedge clock);
        if (!saw_first || !saw_second || keys != 0)
            $fatal(1, "missing loaded keys %0d %0d %h",
                   saw_first, saw_second, keys);
        repeat (5) @(posedge clock);
        if (!finished || keys != 0)
            $fatal(1, "sequence restarted while start remained high");
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
                 SEQUENCER_RTL, testbench_path],
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
