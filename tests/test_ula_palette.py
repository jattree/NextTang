"""The temporary standard-ULA palette must preserve Spectrum colour ordering."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PALETTE_RTL = REPO_ROOT / "rtl" / "video" / "nexttang_ula_palette.v"


class UlaPaletteTest(unittest.TestCase):
    def test_standard_and_bright_colours(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg [7:0] index;
    wire [7:0] red, green, blue;
    nexttang_ula_palette dut (
        .palette_index(index), .red(red), .green(green), .blue(blue));

    task expect_rgb;
        input [7:0] value;
        input [7:0] r, g, b;
        begin
            index = value; #1;
            if (red !== r || green !== g || blue !== b)
                $fatal(1, "index %02x gave %02x/%02x/%02x", value,
                       red, green, blue);
        end
    endtask

    initial begin
        expect_rgb(8'h00, 8'h00, 8'h00, 8'h00); // black
        expect_rgb(8'h02, 8'hc0, 8'h00, 8'h00); // red
        expect_rgb(8'h05, 8'h00, 8'hc0, 8'hc0); // cyan
        expect_rgb(8'h0e, 8'hff, 8'hff, 8'h00); // bright yellow
        // Ink/paper and palette-bank bits do not change standard ULA RGB.
        expect_rgb(8'h92, 8'hc0, 8'h00, 8'h00);
        $display("ULA_PALETTE_PASS");
        $finish;
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            tb = path / "testbench.v"
            sim = path / "simulation.vvp"
            tb.write_text(testbench, encoding="utf-8")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o", str(sim),
                 str(PALETTE_RTL), str(tb)],
                cwd=REPO_ROOT, check=False, capture_output=True, text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run(
                ["vvp", str(sim)], cwd=REPO_ROOT, check=False,
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ULA_PALETTE_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
