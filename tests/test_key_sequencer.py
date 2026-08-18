"""The sequencer has to press keys the way the ROM expects to find them.

The ROM scans once a frame and wants a key held across several scans and then
released before the next. A sequencer that changed keys every cycle, or never
released, would look correct in a waveform and type nothing. These run it with
short timings and check the order, the gaps, and that symbol shift is held with
its key rather than before it.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SEQUENCER = REPO_ROOT / "rtl" / "input" / "nexttang_key_sequencer.v"

# The line the sequencer types, as (row, column, symbol shift).
EXPECTED = [
    (5, 0, False),  # P, which the ROM expands to PRINT
    (5, 0, True),   # quote
    (7, 3, False),  # N
    (2, 2, False),  # E
    (0, 2, False),  # X
    (2, 4, False),  # T
    (2, 4, False),  # T
    (1, 0, False),  # A
    (7, 3, False),  # N
    (1, 4, False),  # G
    (5, 0, True),   # quote
    (6, 0, False),  # ENTER
]


def run(body: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        (path / "tb.v").write_text(body, encoding="utf-8")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-Wall", "-s", "testbench",
             "-o", str(path / "sim.vvp"), str(SEQUENCER), str(path / "tb.v")],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(["vvp", str(path / "sim.vvp")],
                                cwd=REPO_ROOT, check=False,
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


# Short timings so the whole line types in a simulation rather than a second of
# wall clock. The behaviour under test is the order and the gaps, not the rate.
HARNESS = """
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    wire [39:0] keys;
    wire finished;

    nexttang_key_sequencer #(
        .CLOCK_HZ(1000), .START_DELAY_MS(2), .HOLD_MS(3), .GAP_MS(3)
    ) dut (.clock(clock), .reset(reset), .keys(keys), .finished(finished));

    always #5 clock = ~clock;

    integer settled;
    reg [39:0] previous;
    initial begin
        previous = 0;
        settled = 0;
        @(posedge clock); @(posedge clock);
        reset = 0;
        while (!finished && settled < 4000) begin
            @(posedge clock);
            settled = settled + 1;
            if (keys !== previous) begin
                if (keys != 0) $display("PRESS %010x", keys);
                previous = keys;
            end
        end
        $display("DONE finished=%b after %0d cycles", finished, settled);
        $finish;
    end
endmodule
"""


class KeySequencerTest(unittest.TestCase):
    def presses(self) -> list[int]:
        output = run(HARNESS)
        self.assertIn("DONE finished=1", output)
        return [int(line.split()[1], 16)
                for line in output.splitlines() if line.startswith("PRESS")]

    def test_it_types_the_intended_line_in_order(self) -> None:
        presses = self.presses()
        self.assertEqual(len(presses), len(EXPECTED),
                         f"expected {len(EXPECTED)} key presses, saw {len(presses)}")
        for index, (value, (row, column, shift)) in enumerate(zip(presses, EXPECTED)):
            wanted = 1 << (row * 5 + column)
            if shift:
                wanted |= 1 << (7 * 5 + 1)
            self.assertEqual(value, wanted,
                             f"press {index}: got {value:#012x}, wanted {wanted:#012x}")

    def test_every_key_is_released_before_the_next(self) -> None:
        # Without a gap the ROM sees one long press and types a single
        # character, so the release is part of the behaviour, not a detail.
        output = run(HARNESS)
        presses = [line for line in output.splitlines() if line.startswith("PRESS")]
        self.assertEqual(len(presses), len(EXPECTED))
        # A press only prints when the value changed away from something else;
        # consecutive identical keys (the two Ts) only appear twice if the
        # sequencer released in between.
        repeated = [p for p in presses if p == presses[5]]
        self.assertGreaterEqual(len(repeated), 2,
                                "the repeated key was not released between presses")

    def test_symbol_shift_is_held_with_its_key(self) -> None:
        # A quote needs symbol shift down at the same time as P. Pressing them
        # in sequence types the letter instead.
        presses = self.presses()
        quote = presses[1]
        self.assertTrue(quote & (1 << (7 * 5 + 1)), "symbol shift was not held")
        self.assertTrue(quote & (1 << (5 * 5 + 0)), "P was not held with it")


if __name__ == "__main__":
    unittest.main()
