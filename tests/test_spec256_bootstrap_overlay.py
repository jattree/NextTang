"""Regression for the compact Spec256 snapshot bootstrap overlay."""

from pathlib import Path
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]


class Spec256BootstrapOverlayTests(unittest.TestCase):
    def test_low_page_is_writable_and_upper_padding_reads_zero(self) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
 reg clock=0,write_enable=0;reg[13:0]write_address=0,read_address=0;
 reg[7:0]write_data=0;wire[7:0]read_data;
 always#5 clock=~clock;
 nexttang_spec256_bootstrap_overlay dut(
  .clock(clock),.write_enable(write_enable),.write_address(write_address),
  .write_data(write_data),.read_address(read_address),.read_data(read_data));
 task write_byte;input[13:0]a;input[7:0]v;begin
  @(negedge clock);write_enable=1;write_address=a;write_data=v;
  @(negedge clock);write_enable=0;end endtask
 task expect_read;input[13:0]a;input[7:0]v;begin
  read_address=a;@(posedge clock);#1;
  if(read_data!==v)$fatal(1,"read %h got %h expected %h",a,read_data,v);
 end endtask
 initial begin
  write_byte(14'h0044,8'ha5);
  write_byte(14'h00ff,8'h3c);
  // Pack padding writes above the retained page must be ignored rather than
  // aliasing and corrupting the meaningful bootstrap bytes.
  write_byte(14'h0144,8'h5a);
  expect_read(14'h0044,8'ha5);
  expect_read(14'h00ff,8'h3c);
  expect_read(14'h0144,8'h00);
  expect_read(14'h3f44,8'h00);
  expect_read(14'h0044,8'ha5);
  $display("SPEC256_BOOTSTRAP_OVERLAY_PASS");$finish;end
endmodule
"""
        sources = [
            REPO_ROOT / "rtl/memory/nexttang_distributed_ram.v",
            REPO_ROOT / "rtl/memory/nexttang_spec256_bootstrap_overlay.v",
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bench_path = root / "testbench.v"
            bench_path.write_text(bench, encoding="utf-8")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-o", str(root / "sim"),
                 *(str(path) for path in sources), str(bench_path)],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(
                compile_result.returncode, 0,
                compile_result.stdout + compile_result.stderr,
            )
            run = subprocess.run(
                ["vvp", str(root / "sim")], check=False,
                capture_output=True, text=True,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("SPEC256_BOOTSTRAP_OVERLAY_PASS", run.stdout)


if __name__ == "__main__":
    unittest.main()
