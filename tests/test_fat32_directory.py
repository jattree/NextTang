"""Integrated FAT cluster-to-VFAT-directory HDL regression."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from tests.test_fat32_reference import lfn_entries


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = [
    REPO_ROOT / "rtl/storage/nexttang_fat32_cluster_stream.v",
    REPO_ROOT / "rtl/storage/nexttang_fat32_directory_entry.v",
    REPO_ROOT / "rtl/storage/nexttang_fat32_directory.v",
]


class Fat32DirectoryTests(unittest.TestCase):
    def test_directory_stops_at_zero_entry_and_emits_lfn(self) -> None:
        short = b"JETPAC~1TAP"
        ordinary = bytearray(32); ordinary[:11] = short; ordinary[11] = 0x20
        ordinary[26:28] = (9).to_bytes(2, "little"); ordinary[28:32] = (1234).to_bytes(4, "little")
        sector = b"".join((*lfn_entries("Jet Pac Deluxe.tap", short), bytes(ordinary)))
        sector += bytes(512 - len(sector))
        assignments = "\n".join(
            f"sector_mem[{index}]=8'h{byte:02x};"
            for index, byte in enumerate(sector) if byte
        )
        bench = f"""
`timescale 1ns/1ps
module testbench;
 reg clock=0,reset=1,start=0,sector_ready=1,sector_byte_valid=0,sector_done=0,sector_error=0;
 reg [7:0] sector_byte=0;reg [8:0] sector_offset=0;reg [7:0] entry_name_index=0;
 wire sector_start;wire [31:0] sector_lba;wire entry_valid;wire [7:0] entry_attributes;
 wire [31:0] entry_cluster,entry_size;wire [7:0] entry_name_length,entry_name_data;
 wire busy,done,error;reg [7:0] sector_mem[0:511];integer i,seen=0;
 reg [7:0] expected[0:17];always #5 clock=~clock;
 nexttang_fat32_directory dut(.clock(clock),.reset(reset),.start(start),
  .directory_cluster(32'd2),.sectors_per_cluster(8'd1),.fat_lba(32'd2),.data_lba(32'd3),
  .sector_start(sector_start),.sector_lba(sector_lba),.sector_ready(sector_ready),
  .sector_byte(sector_byte),.sector_offset(sector_offset),.sector_byte_valid(sector_byte_valid),
  .sector_done(sector_done),.sector_error(sector_error),.entry_valid(entry_valid),
  .entry_attributes(entry_attributes),.entry_cluster(entry_cluster),.entry_size(entry_size),
  .entry_name_length(entry_name_length),.entry_name_index(entry_name_index),
  .entry_name_data(entry_name_data),.busy(busy),.done(done),.error(error));
 always @(posedge clock)if(entry_valid)seen=seen+1;
 initial begin
  for(i=0;i<512;i=i+1)sector_mem[i]=0;{assignments}
  expected[0]="J";expected[1]="e";expected[2]="t";expected[3]=" ";
  expected[4]="P";expected[5]="a";expected[6]="c";expected[7]=" ";
  expected[8]="D";expected[9]="e";expected[10]="l";expected[11]="u";
  expected[12]="x";expected[13]="e";expected[14]=".";expected[15]="t";
  expected[16]="a";expected[17]="p";
  repeat(3)@(posedge clock);reset=0;@(negedge clock);start=1;@(negedge clock);start=0;
  wait(sector_start);if(sector_lba!=3)$fatal(1,"directory LBA %0d",sector_lba);
  for(i=0;i<512;i=i+1)begin repeat(2)@(negedge clock);sector_offset=i;
    sector_byte=sector_mem[i];sector_byte_valid=1;@(negedge clock);sector_byte_valid=0;end
  @(negedge clock);sector_done=1;@(negedge clock);sector_done=0;
  wait(done);#1;if(error||seen!=1||entry_name_length!=18||entry_cluster!=9||entry_size!=1234)
   $fatal(1,"directory result err=%0d seen=%0d len=%0d cl=%0d size=%0d",error,seen,entry_name_length,entry_cluster,entry_size);
  for(i=0;i<18;i=i+1)begin entry_name_index=i;#1;if(entry_name_data!=expected[i])$fatal(1,"name %0d",i);end
  // A zero directory entry aborts the underlying cluster stream.  Verify that
  // abort is a pulse and does not poison the next catalog directory scan.
  @(negedge clock);start=1;@(negedge clock);start=0;
  wait(!sector_start);wait(sector_start);if(sector_lba!=3)$fatal(1,"second directory LBA %0d",sector_lba);
  for(i=0;i<512;i=i+1)begin repeat(2)@(negedge clock);sector_offset=i;
    sector_byte=sector_mem[i];sector_byte_valid=1;@(negedge clock);sector_byte_valid=0;end
  @(negedge clock);sector_done=1;@(negedge clock);sector_done=0;
  wait(done);#1;if(error||seen!=2)$fatal(1,"second directory result err=%0d seen=%0d",error,seen);
  $display("FAT32_DIRECTORY_PASS");$finish;
 end
 initial begin #500000;$fatal(1,"timeout");end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / "tb.sv"; output = root / "tb.vvp"
            source.write_text(bench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), *(str(item) for item in RTL), str(source)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run(["vvp", str(output)], cwd=REPO_ROOT,
                                 capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("FAT32_DIRECTORY_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
