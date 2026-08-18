"""The keyboard has to answer the way software scans it.

Software does not read one half-row at a time. It drives several address lines
low at once to ask "is anything pressed in any of these", so the answer is the
combination of every selected half-row, not a lookup of one. A matrix that
handles a single row correctly and ignores the rest passes a casual test and
then fails the ROM's own scan.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
MATRIX = REPO_ROOT / "rtl" / "input" / "nexttang_keyboard_matrix.v"

# Row, then column, in the order the hardware scans.
KEYS = {
    "CAPS": (0, 0), "Z": (0, 1), "X": (0, 2), "C": (0, 3), "V": (0, 4),
    "A": (1, 0), "S": (1, 1), "D": (1, 2), "F": (1, 3), "G": (1, 4),
    "Q": (2, 0), "W": (2, 1), "E": (2, 2), "R": (2, 3), "T": (2, 4),
    "1": (3, 0), "2": (3, 1), "3": (3, 2), "4": (3, 3), "5": (3, 4),
    "0": (4, 0), "9": (4, 1), "8": (4, 2), "7": (4, 3), "6": (4, 4),
    "P": (5, 0), "O": (5, 1), "I": (5, 2), "U": (5, 3), "Y": (5, 4),
    "ENTER": (6, 0), "L": (6, 1), "K": (6, 2), "J": (6, 3), "H": (6, 4),
    "SPACE": (7, 0), "SYM": (7, 1), "M": (7, 2), "N": (7, 3), "B": (7, 4),
}


def key_vector(*names: str) -> int:
    value = 0
    for name in names:
        row, column = KEYS[name]
        value |= 1 << (row * 5 + column)
    return value


def run(body: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        (path / "tb.v").write_text(body, encoding="utf-8")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-Wall", "-s", "testbench",
             "-o", str(path / "sim.vvp"), str(MATRIX), str(path / "tb.v")],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(["vvp", str(path / "sim.vvp")],
                                cwd=REPO_ROOT, check=False,
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


HARNESS = """
`timescale 1ns/1ps
module testbench;
    reg [7:0] row_select;
    reg [39:0] keys;
    wire [4:0] columns;
    nexttang_keyboard_matrix dut (.row_select(row_select), .keys(keys),
                                  .columns(columns));
    initial begin
BODY
        $finish;
    end
endmodule
"""


class KeyboardMatrixTest(unittest.TestCase):
    def test_nothing_pressed_reads_all_ones(self) -> None:
        output = run(HARNESS.replace("BODY", """
        keys = 0; row_select = 8'b11111110; #1;
        if (columns !== 5'b11111) $fatal(1, "idle row read %b", columns);
        $display("IDLE_OK");
"""))
        self.assertIn("IDLE_OK", output)

    def test_a_pressed_key_reads_zero_in_its_own_row_only(self) -> None:
        # P is row 5. Selecting row 5 must show it; selecting row 4 must not.
        output = run(HARNESS.replace("BODY", f"""
        keys = 40'd{key_vector("P")};
        row_select = 8'b11011111; #1;                 // row 5 low
        if (columns !== 5'b11110) $fatal(1, "row 5 read %b, expected 11110", columns);
        row_select = 8'b11101111; #1;                 // row 4 low
        if (columns !== 5'b11111) $fatal(1, "row 4 read %b, expected 11111", columns);
        $display("SINGLE_OK");
"""))
        self.assertIn("SINGLE_OK", output)

    def test_selecting_several_rows_combines_them(self) -> None:
        # This is how the ROM asks "is any key pressed at all". Driving every
        # line low must report a key held in any row.
        output = run(HARNESS.replace("BODY", f"""
        keys = 40'd{key_vector("ENTER")};              // row 6, column 0
        row_select = 8'b00000000; #1;                 // scan everything
        if (columns !== 5'b11110) $fatal(1, "full scan read %b, expected 11110", columns);
        row_select = 8'b10111111; #1;                 // row 6 alone
        if (columns !== 5'b11110) $fatal(1, "row 6 read %b", columns);
        row_select = 8'b11111110; #1;                 // row 0 alone
        if (columns !== 5'b11111) $fatal(1, "row 0 should be idle, read %b", columns);
        $display("COMBINED_OK");
"""))
        self.assertIn("COMBINED_OK", output)

    def test_two_keys_in_different_rows_both_report(self) -> None:
        # Symbol shift lives in row 7 and is held with a key from another row,
        # which is how punctuation is typed. Both must show when both rows are
        # selected together.
        output = run(HARNESS.replace("BODY", f"""
        keys = 40'd{key_vector("SYM", "P")};
        row_select = 8'b01011111; #1;                 // rows 5 and 7 low
        if (columns !== 5'b11100) $fatal(1, "shifted read %b, expected 11100", columns);
        $display("SHIFTED_OK");
"""))
        self.assertIn("SHIFTED_OK", output)


if __name__ == "__main__":
    unittest.main()
