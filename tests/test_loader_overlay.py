"""Pixel contracts for the common NextTang Loader overlay."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [REPO_ROOT / "rtl/loader/nexttang_loader_font.v",
           REPO_ROOT / "rtl/loader/nexttang_loader_overlay.v"]


class LoaderOverlayTests(unittest.TestCase):
    def test_title_panel_and_selected_basic_row(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
 reg clock=0,enable=1,ready=1,error=0;reg[2:0]diagnostic_code=0;
 reg[10:0]x=0;reg[9:0]y=0;reg[5:0]selection=0,file_count=1;
 wire[5:0]display_entry,display_name_index;reg[7:0]display_name_data="B",display_name_length=5;
 wire overlay_enable;wire[7:0]red,green,blue;
 always #5 clock=~clock;nexttang_loader_overlay dut(.*);
 initial begin
  #1;if(overlay_enable)$fatal(1,"outside panel enabled");
  x=11'd516;y=10'd140;repeat(2)@(posedge clock);#1;
  if(!overlay_enable||{{red,green,blue}}!=24'hffffff)$fatal(1,"title N pixel %x",{{red,green,blue}});
  x=11'd356;y=10'd194;repeat(2)@(posedge clock);#1;
  if(display_entry!=0||display_name_index!=0)$fatal(1,"BASIC query wrong");
  if({{red,green,blue}}!=24'hfff090)$fatal(1,"selected BASIC pixel %x",{{red,green,blue}});
  x=11'd330;y=10'd130;repeat(2)@(posedge clock);#1;if({{red,green,blue}}!=24'h182858)$fatal(1,"header background");
  $display("LOADER_OVERLAY_PASS");$finish;
 end
endmodule
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / "tb.sv"; output = root / "tb.vvp"
            source.write_text(bench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), *(str(item) for item in SOURCES), str(source)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run(["vvp", str(output)], cwd=REPO_ROOT,
                                 capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("LOADER_OVERLAY_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
