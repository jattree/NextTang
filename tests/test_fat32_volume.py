"""MBR and FAT32 volume-discovery HDL regressions."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/storage/nexttang_fat32_volume.v"


class Fat32VolumeTests(unittest.TestCase):
    def test_mbr_partition_and_root_geometry(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock=0, reset=1, start=0, sector_ready=1;
    reg [7:0] sector_byte=0; reg [8:0] sector_offset=0;
    reg sector_byte_valid=0, sector_done=0, sector_error=0;
    wire sector_start; wire [31:0] sector_lba;
    wire ready,busy,error; wire [1:0] diagnostic_code;
    wire [31:0] partition_lba,fat_lba,data_lba,root_cluster,root_lba;
    wire [7:0] sectors_per_cluster;
    reg [7:0] image [0:1023]; integer i;
    always #5 clock=~clock;
    nexttang_fat32_volume dut(.*);
    task put16(input integer base,input integer off,input [15:0] value);
      begin image[base+off]=value[7:0]; image[base+off+1]=value[15:8]; end
    endtask
    task put32(input integer base,input integer off,input [31:0] value);
      begin image[base+off]=value[7:0]; image[base+off+1]=value[15:8];
        image[base+off+2]=value[23:16]; image[base+off+3]=value[31:24]; end
    endtask
    task stream(input integer base);
      begin
        for(i=0;i<512;i=i+1) begin @(negedge clock); sector_offset=i; sector_byte=image[base+i]; sector_byte_valid=1; end
        @(negedge clock); sector_byte_valid=0; sector_done=1;
        @(negedge clock); sector_done=0;
      end
    endtask
    initial begin
      for(i=0;i<1024;i=i+1) image[i]=0;
      image[510]=8'h55; image[511]=8'haa; image[450]=8'h0c; put32(0,454,32'd2048);
      put16(512,11,16'd512); image[512+13]=8; put16(512,14,32'd32);
      image[512+16]=2; put32(512,36,32'd100); put32(512,44,32'd5);
      image[1022]=8'h55; image[1023]=8'haa;
      repeat(3) @(posedge clock); reset=0;
      @(negedge clock); start=1; @(negedge clock); start=0;
      wait(sector_start); if(sector_lba!=0) $fatal(1,"first request not MBR"); stream(0);
      wait(sector_start); if(sector_lba!=2048) $fatal(1,"boot LBA %0d",sector_lba); stream(512);
      wait(ready||error); if(error) $fatal(1,"volume rejected");
      if(partition_lba!=2048 || sectors_per_cluster!=8 || fat_lba!=2080 ||
         data_lba!=2280 || root_cluster!=5 || root_lba!=2304)
        $fatal(1,"geometry wrong p=%0d spc=%0d fat=%0d data=%0d rootc=%0d root=%0d",
          partition_lba,sectors_per_cluster,fat_lba,data_lba,root_cluster,root_lba);
      $display("FAT32_VOLUME_PASS"); $finish;
    end
    initial begin #200000; $fatal(1,"timeout"); end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "testbench.sv"
            output = root / "testbench.vvp"
            source.write_text(bench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), str(RTL), str(source)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run(["vvp", str(output)], cwd=REPO_ROOT,
                                 capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("FAT32_VOLUME_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
