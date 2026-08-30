"""Spec256 loader/CPU regression for DDR3-backed ordinary main memory."""

from pathlib import Path
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]


class Spec256MainDdrMemoryTests(unittest.TestCase):
    def test_pack_writes_then_cpu_reads_local_and_external_memory(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
 reg cc=0,mc=0,path_reset=1,available=0;
 reg[15:0]ca=0;reg[7:0]cwd=0;reg cmreq=1,crd=1,cwr=1,crfsh=1;
 wire[7:0]rd;wire wait_n;reg lw=0;reg[15:0]la=0;reg[7:0]ld=0;
 wire loader_complete;reg[13:0]va=0;wire[7:0]vd;
 wire lreq,lwrite;reg lready=1;wire[16:0]laddr;wire[127:0]lwdata;
 wire[15:0]lwen;reg lrvalid=0;reg[127:0]lrdata=0;
 wire ft,fo,fc;reg[127:0]lines[0:4095];reg pending=0,pwrite=0;
 reg[11:0]pa=0;reg[127:0]pwd=0;reg[15:0]pwe=0;integer delay=0,i;
 always#5 cc=~cc;always#3 mc=~mc;
 nexttang_spec256_main_ddr_memory dut(
  .cpu_clock(cc),.path_reset(path_reset),.memory_available(available),
  .cpu_address(ca),.cpu_write_data(cwd),.cpu_mreq_n(cmreq),.cpu_rd_n(crd),
  .cpu_wr_n(cwr),.cpu_rfsh_n(crfsh),.ram_read_data(rd),.cpu_wait_n(wait_n),
  .loader_write(lw),.loader_address(la),.loader_write_data(ld),
  .loader_upper_complete(loader_complete),.video_clock(mc),.video_address(va),
  .video_data(vd),.memory_clock(mc),.memory_reset(path_reset),
  .line_request(lreq),.line_ready(lready),.line_write(lwrite),
  .line_address(laddr),.line_write_data(lwdata),.line_write_enable(lwen),
  .line_response_valid(lrvalid),.line_read_data(lrdata),
  .fault_timeout(ft),.fault_overrun(fo),.fault_calibration_lost(fc));
 always@(posedge mc)begin
  lrvalid<=0;
  if(!pending&&lreq&&lready)begin pending<=1;pwrite<=lwrite;pa<=laddr[11:0];
   pwd<=lwdata;pwe<=lwen;delay<=3;end
  else if(pending&&delay>1)delay<=delay-1;
  else if(pending)begin
   if(pwrite)begin for(i=0;i<16;i=i+1)if(pwe[i])lines[pa][i*8+:8]<=pwd[i*8+:8];end
   else lrdata<=lines[pa];lrvalid<=1;pending<=0;end
 end
 task loader_write;input[15:0]a;input[7:0]v;integer n;begin
  @(negedge cc);la<=a;ld<=v;lw<=1;@(negedge cc);lw<=0;
  if(a[15])begin n=0;while(!loader_complete&&n<100)begin @(negedge cc);n=n+1;end
   if(!loader_complete)$fatal(1,"loader DDR write timeout");end
 end endtask
 task cpu_read;input[15:0]a;input[7:0]v;integer n;begin
  @(negedge cc);ca<=a;cmreq<=0;crd<=0;n=0;
  #1;if(a[15])while(!wait_n&&n<100)begin @(negedge cc);n=n+1;end
  else @(negedge cc);
  #1;if(rd!==v)$fatal(1,"read %h got %h expected %h",a,rd,v);
  cmreq<=1;crd<=1;@(negedge cc);
 end endtask
 initial begin repeat(4)@(posedge cc);path_reset<=0;available<=1;
  loader_write(16'h4001,8'h5a);loader_write(16'h8003,8'ha5);
  loader_write(16'hffff,8'h3c);va<=14'h0001;repeat(2)@(posedge mc);
  if(vd!==8'h5a)$fatal(1,"video did not see local loader write");
  cpu_read(16'h4001,8'h5a);cpu_read(16'h8003,8'ha5);cpu_read(16'hffff,8'h3c);
  if(ft||fo||fc)$fatal(1,"unexpected fault");
  $display("SPEC256_MAIN_DDR_MEMORY_PASS");$finish;end
endmodule
"""
        sources = [
            "rtl/memory/nexttang_block_ram.v",
            "rtl/memory/nexttang_cpu_memory_service.v",
            "rtl/memory/nexttang_memory_cdc_bridge.v",
            "rtl/memory/nexttang_byte_line_adapter.v",
            "rtl/memory/nexttang_cpu_memory_path.v",
            "rtl/memory/nexttang_spec256_main_ddr_memory.v",
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            bench_path = path / "testbench.v"
            bench_path.write_text(bench, encoding="utf-8")
            result = subprocess.run(
                ["iverilog", "-g2012", "-o", str(path / "sim"),
                 *(str(REPO_ROOT / source) for source in sources), str(bench_path)],
                check=True, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0)
            run = subprocess.run(["vvp", str(path / "sim")], check=False,
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("SPEC256_MAIN_DDR_MEMORY_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
