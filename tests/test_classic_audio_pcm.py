"""PCM-rate and mixing contracts for classic Spectrum HDMI audio."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PCM_RTL = REPO_ROOT / "rtl/audio/nexttang_classic_audio_pcm.v"


class ClassicAudioPcmTests(unittest.TestCase):
    def test_sample_rate_beeper_and_ay_mix(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, beeper = 0, ay_enable = 0;
    reg [7:0] ay_a = 0, ay_b = 0, ay_c = 0;
    wire audio_ce;
    wire signed [15:0] sample;
    integer cycles = 0, strobes = 0;
    integer beeper_sample = 0, ay_sample = 0;
    always #5 clock = ~clock;

    // Make the arithmetic easy to check: one sample strobe every 16 clocks.
    nexttang_classic_audio_pcm #(.PHASE_INCREMENT(32'h10000000)) dut (
        .clock(clock), .reset(reset), .beeper(beeper),
        .ay_enable(ay_enable), .ay_a(ay_a), .ay_b(ay_b), .ay_c(ay_c),
        .audio_ce(audio_ce), .sample(sample)
    );

    task wait_strobe;
        begin
            @(posedge clock);
            while (!audio_ce) @(posedge clock);
            #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clock); reset = 0;
        repeat (160) begin
            @(posedge clock); #1;
            cycles = cycles + 1;
            if (audio_ce) strobes = strobes + 1;
        end
        if (strobes != 10)
            $fatal(1, "sample cadence was %0d strobes in %0d clocks", strobes, cycles);

        // A beeper edge must produce a positive AC sample.
        beeper = 1;
        wait_strobe;
        beeper_sample = sample;
        if (beeper_sample <= 0)
            $fatal(1, "beeper edge did not produce positive PCM: %0d", beeper_sample);

        // Enabling three maximum AY channels must increase the mixed sample.
        ay_enable = 1; ay_a = 8'hff; ay_b = 8'hff; ay_c = 8'hff;
        repeat (3) @(posedge clock); // two-stage clock-domain synchronizers
        wait_strobe;
        ay_sample = sample;
        if (ay_sample <= beeper_sample)
            $fatal(1, "AY did not increase mix: beeper=%0d ay=%0d",
                   beeper_sample, ay_sample);

        // Disabling AY removes its contribution on a subsequent sample.
        ay_enable = 0;
        wait_strobe;
        if (sample >= ay_sample)
            $fatal(1, "AY disable did not reduce mix: before=%0d after=%0d",
                   ay_sample, sample);
        $display("CLASSIC_AUDIO_PCM_PASS");
        $finish;
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "testbench.v"
            output = root / "testbench.vvp"
            source.write_text(bench, encoding="ascii")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), str(PCM_RTL), str(source)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run(
                ["vvp", str(output)], cwd=REPO_ROOT,
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("CLASSIC_AUDIO_PCM_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
