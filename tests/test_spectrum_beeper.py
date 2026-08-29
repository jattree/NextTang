import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SpectrumBeeperTest(unittest.TestCase):
    def test_even_io_write_latches_bit_four(self):
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg iorq_n = 1;
    reg wr_n = 1;
    reg [15:0] address = 16'hffff;
    reg [7:0] data = 8'h00;
    wire beeper;

    always #5 clock = ~clock;

    nexttang_spectrum_beeper dut (
        .clock(clock),
        .reset(reset),
        .iorq_n(iorq_n),
        .wr_n(wr_n),
        .address(address),
        .data(data),
        .beeper(beeper)
    );

    task tick;
        begin
            @(posedge clock);
            #1;
        end
    endtask

    initial begin
        tick;
        if (beeper !== 1'b0)
            $fatal(1, "reset level was %b", beeper);

        reset = 0;
        iorq_n = 0;
        wr_n = 0;
        address = 16'h00fe;
        data = 8'h10;
        tick;
        if (beeper !== 1'b1)
            $fatal(1, "even port write did not latch bit four");

        address = 16'h00ff;
        data = 8'h00;
        tick;
        if (beeper !== 1'b1)
            $fatal(1, "odd port write changed the beeper");

        address = 16'h00fe;
        wr_n = 1;
        tick;
        if (beeper !== 1'b1)
            $fatal(1, "port read changed the beeper");

        wr_n = 0;
        data = 8'h00;
        tick;
        if (beeper !== 1'b0)
            $fatal(1, "second even port write did not clear bit four");

        $finish;
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
                    "iverilog",
                    "-g2012",
                    "-o",
                    str(output),
                    str(REPO_ROOT / "rtl/audio/nexttang_spectrum_beeper.v"),
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
