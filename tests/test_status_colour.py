"""Colour-code contract for screen-visible hardware diagnostics."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
STATUS_RTL = REPO_ROOT / "rtl" / "smoke" / "nexttang_status_colour.v"


class StatusColourTest(unittest.TestCase):
    def test_every_status_has_a_distinct_expected_colour(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg [2:0] status;
    wire [23:0] colour;
    reg [23:0] expected [0:7];
    integer index;

    nexttang_status_colour dut (.status(status), .colour(colour));

    initial begin
        expected[0] = 24'h003080;
        expected[1] = 24'hff8800;
        expected[2] = 24'h00a0c0;
        expected[3] = 24'h00b050;
        expected[4] = 24'hd00000;
        expected[5] = 24'ha000a0;
        expected[6] = 24'hffff00;
        expected[7] = 24'h6000a0;
        for (index = 0; index < 8; index = index + 1) begin
            status = index[2:0];
            #1;
            if (colour != expected[index])
                $fatal(1, "status %0d had colour %h", index, colour);
        end
        $display("STATUS_COLOUR_PASS");
        $finish;
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.v"
            simulation_path = temporary_path / "simulation.vvp"
            testbench_path.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                [
                    "iverilog",
                    "-g2012",
                    "-Wall",
                    "-s",
                    "testbench",
                    "-o",
                    str(simulation_path),
                    str(STATUS_RTL),
                    str(testbench_path),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            simulation_result = subprocess.run(
                ["vvp", str(simulation_path)],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                simulation_result.returncode,
                0,
                simulation_result.stdout + simulation_result.stderr,
            )
            self.assertIn("STATUS_COLOUR_PASS", simulation_result.stdout)


if __name__ == "__main__":
    unittest.main()
