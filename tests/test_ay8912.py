"""Register and tone contracts for the NextTang AY-3-8912 core."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
AY_RTL = REPO_ROOT / "rtl/audio/nexttang_ay8912.v"


class Ay8912Tests(unittest.TestCase):
    def test_register_readback_mixer_gate_and_tone(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1;
    reg select_write = 0, data_write = 0, data_read = 0;
    reg [7:0] write_data = 0;
    wire [7:0] read_data, channel_a, channel_b, channel_c;
    integer transitions = 0;
    reg [7:0] previous_a = 0;
    always #5 clock = ~clock;

    nexttang_ay8912 dut (
        .clock(clock), .reset(reset),
        .select_write(select_write), .data_write(data_write),
        .data_read(data_read), .write_data(write_data),
        .read_data(read_data), .channel_a(channel_a),
        .channel_b(channel_b), .channel_c(channel_c)
    );

    task select_reg(input [3:0] regno);
        begin
            @(negedge clock); write_data = {4'b0, regno}; select_write = 1;
            @(posedge clock); @(negedge clock); select_write = 0;
        end
    endtask
    task write_reg(input [3:0] regno, input [7:0] value);
        begin
            select_reg(regno);
            write_data = value; data_write = 1;
            @(posedge clock); @(negedge clock); data_write = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clock); reset = 0;
        write_reg(4'd0, 8'h01);       // channel A tone period
        write_reg(4'd1, 8'h00);
        write_reg(4'd7, 8'b00111110); // A tone on, noise disabled
        write_reg(4'd8, 8'h0f);       // fixed maximum A volume

        select_reg(4'd8); data_read = 1; #1;
        if (read_data !== 8'h0f) $fatal(1, "register readback was %02x", read_data);
        data_read = 0;
        if (channel_b !== 0 || channel_c !== 0)
            $fatal(1, "disabled channels were not silent");

        previous_a = channel_a;
        repeat (80) begin
            @(posedge clock); #1;
            if (channel_a != previous_a) begin
                transitions = transitions + 1;
                previous_a = channel_a;
            end
        end
        if (transitions < 2)
            $fatal(1, "tone A did not oscillate, transitions=%0d", transitions);

        write_reg(4'd8, 8'h00);
        #1;
        if (channel_a !== 0) $fatal(1, "zero volume did not silence A");
        $display("AY8912_PASS");
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
                 str(output), str(AY_RTL), str(source)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run(
                ["vvp", str(output)], cwd=REPO_ROOT,
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("AY8912_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
