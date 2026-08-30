"""Common NextTang Loader catalog/navigation/dispatch HDL regression."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl/loader/nexttang_loader_catalog.v"


class LoaderCatalogTests(unittest.TestCase):
    def test_classic48_path_basic_navigation_and_tap_dispatch(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
 reg clock=0,reset=1,storage_ready=0,storage_busy=0,storage_done=0,storage_error=0;
 reg entry_valid=0;reg[7:0]entry_attributes=0;reg[31:0]entry_cluster=0,entry_size=0;
 reg[7:0]entry_name_length=0;wire[7:0]entry_name_index;reg[7:0]name[0:47];
 wire[7:0]entry_name_data=name[entry_name_index];reg[7:0]storage_file_byte=0;
 reg[31:0]storage_file_offset=0;reg storage_file_valid=0,navigate_up=0,navigate_down=0,activate=0,open_menu=0;
 wire directory_start;wire[31:0]directory_cluster;wire file_start;wire[31:0]file_cluster,file_size;
 wire menu_ready,menu_active;wire[5:0]selection,file_count;wire display_clock=clock;reg[5:0]display_entry=0,display_name_index=0;
 wire[7:0]display_name_data,display_name_length;wire basic_selected,content_start;
 wire[7:0]content_byte;wire[31:0]content_offset;wire content_valid,content_done;
 wire[2:0]content_format;wire error;integer i;
 always #5 clock=~clock;
 nexttang_loader_catalog #(.MACHINE_KIND(0),.MAX_ENTRIES(4),.MAX_NAME(48))dut(.*);
 task set_name(input integer length,input [8*48-1:0]text_value);
  begin entry_name_length=length;for(i=0;i<48;i=i+1)name[i]=
    i<length?text_value[(length-1-i)*8+:8]:0;end endtask
 task emit(input[7:0]attr,input[31:0]cluster,input[31:0]size);
  begin entry_attributes=attr;entry_cluster=cluster;entry_size=size;
   @(negedge clock);entry_valid=1;@(negedge clock);entry_valid=0;repeat(60)@(posedge clock);end endtask
 task finish_scan;begin @(negedge clock);storage_done=1;@(negedge clock);storage_done=0;end endtask
 task pulse_down;begin @(negedge clock);navigate_down=1;@(negedge clock);navigate_down=0;end endtask
 task pulse_up;begin @(negedge clock);navigate_up=1;@(negedge clock);navigate_up=0;end endtask
 task pulse_activate;begin @(negedge clock);activate=1;@(negedge clock);activate=0;end endtask
 initial begin
  for(i=0;i<48;i=i+1)name[i]=0;repeat(3)@(posedge clock);reset=0;storage_ready=1;
  wait(directory_start);#1;if(directory_cluster!=0)$fatal(1,"root cluster command");
  set_name(5,"games");emit(8'h10,32'd12,0);finish_scan();
  wait(directory_start);#1;if(directory_cluster!=12)$fatal(1,"games cluster %0d",directory_cluster);
  set_name(9,"Classic48");emit(8'h10,32'd34,0);finish_scan();
  wait(directory_start);#1;if(directory_cluster!=34)$fatal(1,"target cluster %0d",directory_cluster);
  set_name(11,"Jet Pac.tap");emit(8'h20,32'd56,32'd700);finish_scan();
  wait(menu_ready);#1;if(error||file_count!=1||selection!=0)$fatal(1,"menu failed");
  display_entry=0;display_name_index=0;repeat(2)@(posedge clock);#1;if(display_name_data!="B")$fatal(1,"BASIC label");
  display_entry=1;display_name_index=4;repeat(2)@(posedge clock);#1;if(display_name_data!="P")$fatal(1,"file label");
  pulse_down();#1;if(selection!=1)$fatal(1,"selection did not move");
  pulse_activate();wait(file_start);#1;
  if(file_cluster!=56||file_size!=700||content_format!=1||menu_active)$fatal(1,"TAP dispatch");
  storage_file_byte=8'ha5;storage_file_offset=0;storage_file_valid=1;@(posedge clock);#1;
  if(!content_valid||content_byte!=8'ha5||content_offset!=0)$fatal(1,"content forwarding");
  storage_file_valid=0;finish_scan();wait(content_done);#1;if(menu_active)$fatal(1,"menu covered running core");
  @(negedge clock);open_menu=1;@(negedge clock);open_menu=0;#1;if(!menu_active)$fatal(1,"menu reopen failed");
  pulse_up();pulse_activate();#1;if(!basic_selected)$fatal(1,"BASIC action missing");
  $display("LOADER_CATALOG_PASS");$finish;
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
            self.assertIn("LOADER_CATALOG_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
