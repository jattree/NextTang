import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class BeeperPcmTest(unittest.TestCase):
    def test_generates_audio_enable_and_bipolar_pcm(self):
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg beeper = 0;
    wire audio_ce;
    wire signed [15:0] sample;

    always #5 clock = ~clock;

    nexttang_beeper_pcm #(
        .PHASE_INCREMENT(32'h40000000),
        .AMPLITUDE(16'sd4096),
        .BASELINE_SHIFT(2)
    ) dut (
        .clock(clock),
        .reset(reset),
        .beeper(beeper),
        .audio_ce(audio_ce),
        .sample(sample)
    );

    task tick;
        begin
            @(posedge clock);
            #1;
        end
    endtask

    initial begin
        tick;
        if (audio_ce !== 0 || sample !== 16'sd0)
            $fatal(1, "bad reset outputs: ce=%b sample=%0d", audio_ce, sample);

        reset = 0;
        tick;
        tick;
        tick;
        tick;
        if (audio_ce !== 1)
            $fatal(1, "phase accumulator did not produce a one-cycle enable");
        tick;
        if (audio_ce !== 0)
            $fatal(1, "audio enable was wider than one cycle");
        if (sample !== 16'sd0)
            $fatal(1, "idle speaker produced DC: %0d", sample);

        beeper = 1;
        repeat (8) tick;
        if (sample <= 16'sd0)
            $fatal(1, "rising speaker edge did not produce positive PCM: %0d", sample);

        beeper = 0;
        repeat (8) tick;
        if (sample >= 16'sd0)
            $fatal(1, "falling speaker edge did not produce negative PCM: %0d", sample);

        repeat (160) tick;
        if (sample > 16'sd4 || sample < -16'sd4)
            $fatal(1, "idle speaker did not decay to silence: %0d", sample);

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
                    str(REPO_ROOT / "rtl/audio/nexttang_beeper_pcm.v"),
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
