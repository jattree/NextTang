"""The Next's audio must reach the HDMI clock as centred 48 kHz PCM.

rtl/audio/nexttang_zxnext_audio_pcm.v takes the core's unsigned 13-bit stereo
mix from the 28 MHz domain to the 75 MHz pixel clock. The test plays a square
wave on the left channel and a different one on the right, both riding on a
large DC level, and checks the sample rate (48 kHz scaled by 75 / 74.25, the
rate an HDMI sink regenerates from this board's clock), that each channel settles around
zero with the swing of its input, and that the channels stay apart.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
PCM_RTL = REPO_ROOT / "rtl" / "audio" / "nexttang_zxnext_audio_pcm.v"

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg core_clock = 0;
    reg clock = 0;
    reg reset = 1;
    reg [12:0] core_left = 0;
    reg [12:0] core_right = 0;
    wire audio_ce;
    wire signed [15:0] left, right;

    nexttang_zxnext_audio_pcm dut (
        .core_clock(core_clock), .core_left(core_left), .core_right(core_right),
        .clock(clock), .reset(reset), .audio_ce(audio_ce), .left(left), .right(right)
    );

    always #17.857 core_clock = !core_clock;   // 28 MHz
    always #6.667 clock = !clock;              // 75 MHz

    // Left: 1 kHz between 3000 and 5000. Right: 250 Hz between 1000 and 1400.
    always #500000 core_left = (core_left == 13'd5000) ? 13'd3000 : 13'd5000;
    always #2000000 core_right = (core_right == 13'd1400) ? 13'd1000 : 13'd1400;

    integer samples = 0;
    integer left_min = 0, left_max = 0, right_min = 0, right_max = 0;
    real left_sum = 0, right_sum = 0;
    time first_sample = 0, last_sample = 0;

    always @(posedge clock) if (audio_ce) begin
        samples = samples + 1;
        // Let the DC baseline settle for the first 0.4 s, then measure.
        if (samples > 19200) begin
            if (first_sample == 0) first_sample = $time;
            last_sample = $time;
            left_sum = left_sum + left;
            right_sum = right_sum + right;
            if (left < left_min) left_min = left;
            if (left > left_max) left_max = left;
            if (right < right_min) right_min = right;
            if (right > right_max) right_max = right;
        end
    end

    initial begin
        repeat (4) @(posedge clock);
        reset = 0;
        #500_000_000;
        $display("RATE %0d", (samples - 19201) * 64'd1000000000 / (last_sample - first_sample));
        $display("LEFT %0d %0d %0d", left_min, left_max, $rtoi(left_sum / (samples - 19200)));
        $display("RIGHT %0d %0d %0d", right_min, right_max, $rtoi(right_sum / (samples - 19200)));
        $display("AUDIO_PCM_DONE");
        $finish;
    end
endmodule
"""


class ZxnextAudioPcmTest(unittest.TestCase):
    def test_stereo_mix_reaches_hdmi_clock_centred(self) -> None:
        output = run_testbench(TESTBENCH, PCM_RTL)
        self.assertIn("AUDIO_PCM_DONE", output)
        values = {line.split()[0]: [int(v) for v in line.split()[1:]]
                  for line in output.splitlines() if line.startswith(("RATE", "LEFT", "RIGHT"))}
        self.assertAlmostEqual(values["RATE"][0], 48485, delta=20)
        # Input swings are 2000 and 400 counts, four output counts each. The
        # DC remover is a high-pass filter with a 256-sample time constant, so
        # each half-cycle droops a little and the peaks overshoot by up to ~10%.
        left_min, left_max, left_mean = values["LEFT"]
        right_min, right_max, right_mean = values["RIGHT"]
        self.assertTrue(7600 <= left_max - left_min <= 8800, left_max - left_min)
        self.assertTrue(1520 <= right_max - right_min <= 1760 * 1.1, right_max - right_min)
        self.assertLess(abs(left_mean), 400)
        self.assertLess(abs(right_mean), 100)


if __name__ == "__main__":
    unittest.main()
