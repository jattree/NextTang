"""Dual-clock buffered SD-to-TZX waveform regression."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    REPO_ROOT/"rtl/memory/nexttang_rom.v",
    REPO_ROOT/"rtl/input/nexttang_tzx_player.v",
    REPO_ROOT/"rtl/loader/nexttang_async_byte_fifo.v",
    REPO_ROOT/"rtl/loader/nexttang_tzx_stream.v",
]


class TzxStreamTests(unittest.TestCase):
    def test_dual_clock_buffer_preserves_tape(self) -> None:
        tape=b"ZXTape!\x1a\x01\x14\x30\x02ok\x10\x02\x00\x01\x00\x00"
        assignments="\n".join(f"image[{i}]=8'h{b:02x};" for i,b in enumerate(tape))
        bench=f"""
`timescale 1ns/1ps
module testbench;
 reg write_clock=0,tape_clock=0,write_reset=1,tape_reset=1,content_start=0,play_start=0;
 reg[7:0]content_byte=0;reg content_valid=0,content_done=0;wire file_pause,fifo_overflow;
 wire ear,active,finished,fault,fault_unsupported;reg[7:0]image[0:{len(tape)-1}];
 integer i,toggles=0;reg previous=0;always #5 write_clock=~write_clock;always #7 tape_clock=~tape_clock;
 always @(posedge tape_clock)begin previous<=ear;if(ear!=previous)toggles<=toggles+1;end
 nexttang_tzx_stream #(.CLOCK_HZ(1000),.STANDARD_PILOT_LENGTH(2),
  .STANDARD_SYNC1_LENGTH(2),.STANDARD_SYNC2_LENGTH(2),.STANDARD_ZERO_LENGTH(2),
  .STANDARD_ONE_LENGTH(3),.HEADER_PILOT_PULSES(3),.DATA_PILOT_PULSES(2))dut(.*);
 initial begin {assignments}
  repeat(3)@(posedge write_clock);write_reset=0;tape_reset=0;
  @(negedge write_clock);content_start=1;@(negedge write_clock);content_start=0;
  for(i=0;i<{len(tape)};i=i+1)begin wait(!file_pause);@(negedge write_clock);
   content_byte=image[i];content_valid=1;@(negedge write_clock);content_valid=0;end
  @(negedge write_clock);content_done=1;@(negedge write_clock);content_done=0;
  repeat(5)@(negedge tape_clock);if(active||finished)$fatal(1,"played before gate");
  play_start=1;@(negedge tape_clock);play_start=0;
  wait(finished);#1;if(fault||fifo_overflow||toggles!=22)$fatal(1,"result f=%0d o=%0d t=%0d",fault,fifo_overflow,toggles);
  $display("TZX_DUAL_CLOCK_STREAM_PASS");$finish;end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/"tb.sv";output=root/"tb.vvp"
            source.write_text(bench,encoding="ascii")
            compiled=subprocess.run(["iverilog","-g2012","-s","testbench","-o",str(output),
                *(str(item) for item in SOURCES),str(source)],cwd=REPO_ROOT,capture_output=True,text=True,check=False)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            run=subprocess.run(["vvp",str(output)],cwd=REPO_ROOT,capture_output=True,text=True,check=False)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn("TZX_DUAL_CLOCK_STREAM_PASS",run.stdout)


if __name__=="__main__":unittest.main()
