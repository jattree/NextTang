"""External byte-stream mode for the bounded TZX pulse player."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [REPO_ROOT / "rtl/memory/nexttang_rom.v",
           REPO_ROOT / "rtl/input/nexttang_tzx_player.v"]


class TzxStreamPlayerTests(unittest.TestCase):
    def test_external_handshake_matches_rom_backed_pulses(self) -> None:
        tape = b"ZXTape!\x1a\x01\x14\x30\x02ok\x10\x02\x00\x01\x00\x00"
        assignments = "\n".join(f"image[{i}]=8'h{b:02x};" for i, b in enumerate(tape))
        bench = f"""
`timescale 1ns/1ps
module testbench;
 reg clock=0,reset=1,start=0;reg[7:0]image[0:{len(tape)-1}];integer position=0,toggles=0;
 wire[7:0]stream_data=image[position];wire stream_valid=position<{len(tape)};
 wire stream_end=position=={len(tape)};wire stream_ready,ear,active,finished,fault,fault_unsupported;
 wire[7:0]current_block;wire[16:0]byte_position;wire[31:0]first_data_bytes;reg previous=0;
 always #5 clock=~clock;
 always @(posedge clock)begin if(stream_ready&&stream_valid)position<=position+1;
  previous<=ear;if(ear!=previous)toggles<=toggles+1;end
 nexttang_tzx_player #(.CLOCK_HZ(1000),.EXTERNAL_STREAM(1),.TZX_BYTES(0),
  .STANDARD_PILOT_LENGTH(2),.STANDARD_SYNC1_LENGTH(2),.STANDARD_SYNC2_LENGTH(2),
  .STANDARD_ZERO_LENGTH(2),.STANDARD_ONE_LENGTH(3),.HEADER_PILOT_PULSES(3),
  .DATA_PILOT_PULSES(2))dut(.clock(clock),.reset(reset),.start(start),
  .stream_data(stream_data),.stream_valid(stream_valid),.stream_end(stream_end),
  .stream_ready(stream_ready),.ear(ear),.active(active),.finished(finished),
  .fault(fault),.fault_unsupported(fault_unsupported),.current_block(current_block),
  .byte_position(byte_position),.first_data_bytes(first_data_bytes));
 initial begin {assignments}
  repeat(2)@(posedge clock);reset=0;start=1;wait(finished);#1;
  if(fault||toggles!=22||position!={len(tape)})$fatal(1,"stream result f=%0d t=%0d p=%0d",fault,toggles,position);
  $display("TZX_STREAM_PLAYER_PASS");$finish;end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / "tb.sv"; output = root / "tb.vvp"
            source.write_text(bench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-s", "testbench", "-o", str(output),
                 *(str(item) for item in SOURCES), str(source)], cwd=REPO_ROOT,
                capture_output=True, text=True, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run(["vvp", str(output)], cwd=REPO_ROOT,
                                 capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("TZX_STREAM_PLAYER_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
