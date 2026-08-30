"""Synthesizable VFAT directory-entry decoder regressions."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from tests.test_fat32_reference import lfn_entries


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/storage/nexttang_fat32_directory_entry.v"


def vector(entry: bytes) -> str:
    return f"256'h{int.from_bytes(entry, 'little'):064x}"


class Fat32DirectoryEntryTests(unittest.TestCase):
    def test_valid_lfn_and_bad_checksum_fallback(self) -> None:
        short = b"JETPAC~1TAP"
        fragments = lfn_entries("Jet Pac Deluxe.tap", short)
        ordinary = bytearray(32)
        ordinary[:11] = short; ordinary[11] = 0x20
        ordinary[20:22] = (0x1234).to_bytes(2, "little")
        ordinary[26:28] = (0x5678).to_bytes(2, "little")
        ordinary[28:32] = (700).to_bytes(4, "little")
        corrupt = bytearray(fragments[0]); corrupt[13] ^= 0x55
        feeds = "\n".join(f"feed({vector(entry)});" for entry in (*fragments, bytes(ordinary)))
        bench = f"""
`timescale 1ns/1ps
module testbench;
 reg clock=0,reset=1,clear=0,entry_start=0; reg [255:0] entry_data=0; reg [7:0] name_index=0;
 wire busy,entry_done,file_valid,end_directory; wire [7:0] attributes,name_length,name_data;
 wire [31:0] first_cluster,file_size; integer i; reg [7:0] expected [0:17];
 always #5 clock=~clock;
 nexttang_fat32_directory_entry dut(.*);
 task feed(input [255:0] value); begin
   wait(!busy); @(negedge clock); entry_data=value; entry_start=1;
   @(negedge clock); entry_start=0; wait(entry_done); #1;
 end endtask
 initial begin
   expected[0]="J";expected[1]="e";expected[2]="t";expected[3]=" ";
   expected[4]="P";expected[5]="a";expected[6]="c";expected[7]=" ";
   expected[8]="D";expected[9]="e";expected[10]="l";expected[11]="u";
   expected[12]="x";expected[13]="e";expected[14]=".";expected[15]="t";
   expected[16]="a";expected[17]="p";
   repeat(3) @(posedge clock); reset=0;
   {feeds}
   if(!file_valid || name_length!=18 || first_cluster!=32'h12345678 || file_size!=700)
     $fatal(1,"LFN metadata mismatch valid=%0d len=%0d cluster=%x size=%0d",
            file_valid,name_length,first_cluster,file_size);
   for(i=0;i<18;i=i+1) begin name_index=i; #1;
     if(name_data!=expected[i]) $fatal(1,"LFN char %0d = %02x",i,name_data); end

   // A mismatched LFN checksum must not be trusted.
   feed({vector(bytes(corrupt))}); feed({vector(bytes(ordinary))});
   if(!file_valid || name_length!=12) $fatal(1,"short fallback length=%0d",name_length);
   name_index=8; #1; if(name_data!=".") $fatal(1,"8.3 fallback lacks dot");
   $display("FAT32_DIRECTORY_ENTRY_PASS"); $finish;
 end
 initial begin #200000; $fatal(1,"timeout"); end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / "testbench.sv"; output = root / "tb.vvp"
            source.write_text(bench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), str(RTL), str(source)], cwd=REPO_ROOT,
                capture_output=True, text=True, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run(["vvp", str(output)], cwd=REPO_ROOT,
                                 capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("FAT32_DIRECTORY_ENTRY_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
