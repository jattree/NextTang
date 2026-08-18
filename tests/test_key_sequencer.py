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

# The program the sequencer types, as (row, column, symbol shift).
#
#   10 PRINT "nexttang was here"
#   20 GOTO 10
#   RUN
EXPECTED = [
    (3, 0, False),  # 1
    (4, 0, False),  # 0
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
    (7, 0, False),  # space
    (2, 1, False),  # W
    (1, 0, False),  # A
    (1, 1, False),  # S
    (7, 0, False),  # space
    (6, 4, False),  # H
    (2, 2, False),  # E
    (2, 3, False),  # R
    (2, 2, False),  # E
    (5, 0, True),   # quote
    (6, 0, False),  # ENTER
    (3, 1, False),  # 2
    (4, 0, False),  # 0
    (1, 4, False),  # G, which the ROM expands to GOTO
    (3, 0, False),  # 1
    (4, 0, False),  # 0
    (6, 0, False),  # ENTER
    (2, 3, False),  # R, which the ROM expands to RUN
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
        while (settled < 6000) begin
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
        return [int(line.split()[1], 16)
                for line in output.splitlines() if line.startswith("PRESS")]

    def test_it_types_the_intended_program_in_order(self) -> None:
        # Only the first presses are the program. The sequencer keeps tapping
        # ENTER afterwards on purpose, so trailing presses are expected.
        presses = self.presses()[:len(EXPECTED)]
        self.assertEqual(len(presses), len(EXPECTED),
                         f"expected {len(EXPECTED)} presses, saw {len(presses)}")
        for index, (value, (row, column, shift)) in enumerate(zip(presses, EXPECTED)):
            wanted = 1 << (row * 5 + column)
            if shift:
                wanted |= 1 << (7 * 5 + 1)
            self.assertEqual(value, wanted,
                             f"press {index}: got {value:#012x}, wanted {wanted:#012x}")

    def test_symbol_shift_is_held_with_its_key(self) -> None:
        # A quote needs symbol shift down at the same time as P. Pressing them
        # in sequence types the letter instead.
        quote_positions = [i for i, (_, _, shift) in enumerate(EXPECTED) if shift]
        self.assertTrue(quote_positions, "the program has no shifted key to check")
        presses = self.presses()
        for position in quote_positions:
            value = presses[position]
            self.assertTrue(value & (1 << (7 * 5 + 1)),
                            f"press {position}: symbol shift was not held")
            self.assertTrue(value & (1 << (5 * 5 + 0)),
                            f"press {position}: P was not held with it")

    def test_repeated_keys_are_released_between_presses(self) -> None:
        # Two Ts in a row only appear as two presses if the key was released in
        # between. Without that the ROM reads one long press as one character.
        presses = self.presses()[:len(EXPECTED)]
        t_key = 1 << (2 * 5 + 4)
        self.assertEqual(presses[7], t_key)
        self.assertEqual(presses[8], t_key)

    def test_it_keeps_tapping_enter_to_hold_the_scroll_open(self) -> None:
        # A listing that fills the screen waits at "scroll?" for a key, so the
        # sequencer must go on pressing something after the program is typed.
        presses = self.presses()
        self.assertGreater(len(presses), len(EXPECTED),
                           "nothing was pressed after the program was typed")
        enter = 1 << (6 * 5 + 0)
        trailing = presses[len(EXPECTED):]
        self.assertTrue(all(value == enter for value in trailing),
                        f"expected only ENTER after the program, saw {set(trailing)}")


if __name__ == "__main__":
    unittest.main()
