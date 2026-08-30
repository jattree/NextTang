"""FAT32 fragmented cluster-chain streaming HDL regression."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/storage/nexttang_fat32_cluster_stream.v"


class Fat32ClusterStreamTests(unittest.TestCase):
    def test_fragmented_chain_respects_exact_file_size(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
 reg clock=0,reset=1,start=0,abort=0,sector_ready=1;
 reg [7:0] sector_byte=0; reg [8:0] sector_offset=0;
 reg sector_byte_valid=0,sector_done=0,sector_error=0;
 wire sector_start; wire [31:0] sector_lba; wire [7:0] stream_byte;
 wire [31:0] stream_offset; wire stream_valid,busy,done,error;
 integer requests=0, seen=0, i; reg [31:0] requested [0:3];
 always #5 clock=~clock;
 nexttang_fat32_cluster_stream dut(
  .clock(clock),.reset(reset),.start(start),.abort(abort),.pause_requests(1'b0),
  .first_cluster(32'd4),.byte_limit(32'd700),.sectors_per_cluster(8'd1),
  .fat_lba(32'd2),.data_lba(32'd3),.sector_start(sector_start),
  .sector_lba(sector_lba),.sector_ready(sector_ready),.sector_byte(sector_byte),
  .sector_offset(sector_offset),.sector_byte_valid(sector_byte_valid),
  .sector_done(sector_done),.sector_error(sector_error),.stream_byte(stream_byte),
  .stream_offset(stream_offset),.stream_valid(stream_valid),.busy(busy),
  .done(done),.error(error));
 task stream_data(input integer cluster_number);
  begin for(i=0;i<512;i=i+1) begin @(negedge clock); sector_offset=i;
   sector_byte=(cluster_number*17+i)&8'hff; sector_byte_valid=1; end
   @(negedge clock); sector_byte_valid=0; sector_done=1;
   @(negedge clock); sector_done=0; end
 endtask
 task stream_fat(input [31:0] following);
  begin for(i=0;i<512;i=i+1) begin @(negedge clock); sector_offset=i;
   case(i) 16:sector_byte=following[7:0];17:sector_byte=following[15:8];
    18:sector_byte=following[23:16];19:sector_byte=following[31:24];
    24:sector_byte=8'hff;25:sector_byte=8'hff;26:sector_byte=8'hff;
    27:sector_byte=8'h0f;default:sector_byte=0;endcase sector_byte_valid=1; end
   @(negedge clock); sector_byte_valid=0; sector_done=1;
   @(negedge clock); sector_done=0; end
 endtask
 always @(posedge clock) if(sector_start) begin
   requested[requests]=sector_lba; requests=requests+1;
 end
 always @(posedge clock) if(stream_valid) begin
   if(stream_offset!=seen) $fatal(1,"stream offset %0d at byte %0d",stream_offset,seen);
   if(seen<512 && stream_byte!=((4*17+seen)&8'hff)) $fatal(1,"cluster4 byte %0d",seen);
   if(seen>=512 && stream_byte!=((6*17+seen-512)&8'hff)) $fatal(1,"cluster6 byte %0d",seen);
   seen=seen+1;
 end
 initial begin
  repeat(3) @(posedge clock);reset=0;@(negedge clock);start=1;@(negedge clock);start=0;
  wait(sector_start);stream_data(4);
  wait(sector_start);if(sector_lba!=2)$fatal(1,"FAT LBA %0d",sector_lba);stream_fat(6);
  wait(sector_start);stream_data(6);
  wait(done);#1;if(error||seen!=700||requests!=3)$fatal(1,"result e=%0d seen=%0d req=%0d",error,seen,requests);
  if(requested[0]!=5||requested[1]!=2||requested[2]!=7)$fatal(1,"LBA sequence wrong");
  $display("FAT32_CLUSTER_STREAM_PASS");$finish;
 end
 initial begin #500000;$fatal(1,"timeout");end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / "tb.sv"; output = root / "tb.vvp"
            source.write_text(bench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), str(RTL), str(source)], cwd=REPO_ROOT,
                capture_output=True, text=True, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run(["vvp", str(output)], cwd=REPO_ROOT,
                                 capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("FAT32_CLUSTER_STREAM_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
