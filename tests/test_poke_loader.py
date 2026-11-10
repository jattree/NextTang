"""Behavioural checks for atomic, bank-aware POKE loading."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.poke import MACHINES, TARGETS, Poke, build_image


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL = REPO_ROOT / "rtl" / "loader" / "nexttang_poke_loader.v"


class PokeLoaderTests(unittest.TestCase):
    def run_loader(self, image: bytes, machine: int, *, fault: bool = False) -> None:
        bench = r"""
`timescale 1ns/1ps
module testbench;
  localparam N=__N__, MACHINE=__MACHINE__;
  reg clock=0,reset=1,start=0,valid=0,done=0,write_ready=1;
  reg[7:0]data=0,stream[0:N-1]; integer i,writes=0;
  wire hold,ready,fault,write_valid;wire[1:0]target;wire[2:0]bank;
  wire[15:0]address;wire[7:0]write_data;
  always #5 clock=!clock;
  nexttang_poke_loader #(.MACHINE_KIND(MACHINE)) dut(
    .clock(clock),.reset(reset),.content_start(start),.byte_data(data),
    .byte_valid(valid),.content_done(done),.hold_cpu(hold),.ready(ready),
    .fault(fault),.write_valid(write_valid),.write_ready(write_ready),
    .write_target(target),.write_bank(bank),.write_address(address),
    .write_data(write_data));
  always @(posedge clock)if(write_valid&&write_ready)begin
    case(writes)
      0:if({target,bank,address,write_data}!=={2'd0,3'd0,16'h8000,8'h2a})
          $fatal(1,"write zero mismatch");
      1:if({target,bank,address,write_data}!=={2'd1,3'd6,16'h1234,8'h63})
          $fatal(1,"write one mismatch");
    endcase
    writes<=writes+1;
  end
  initial begin
    $readmemh("stream.mem",stream);repeat(2)@(posedge clock);reset<=0;
    @(posedge clock);start<=1;@(posedge clock);start<=0;
    for(i=0;i<N;i=i+1)begin data<=stream[i];valid<=1;@(posedge clock);valid<=0;@(posedge clock);end
    if(writes!=0)$fatal(1,"writes escaped before CRC validation");
    done<=1;@(posedge clock);done<=0;
    repeat(8)@(posedge clock);
    if(__FAULT__)begin if(!fault||writes!=0)$fatal(1,"bad image accepted");end
    else begin if(!ready||fault||writes!=2)$fatal(1,"valid image failed");end
    $display("PASS");$finish;
  end
endmodule
""".replace("__N__", str(len(image))).replace(
            "__MACHINE__", str(machine)
        ).replace("__FAULT__", "1" if fault else "0")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stream.mem").write_text(
                "".join(f"{byte:02x}\n" for byte in image), encoding="ascii"
            )
            (root / "testbench.v").write_text(bench, encoding="ascii")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-o", str(root / "sim"),
                 str(root / "testbench.v"), str(RTL)],
                cwd=root, capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run(
                ["vvp", str(root / "sim")], cwd=root,
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)

    def test_valid_image_is_applied_only_after_crc(self) -> None:
        self.run_loader(build_image(MACHINES["128k"], (
            Poke(TARGETS["logical"], 0, 0x8000, 42),
            Poke(TARGETS["bank"], 6, 0x1234, 99),
        )), MACHINES["128k"])

    def test_corrupt_image_never_writes(self) -> None:
        image = bytearray(build_image(MACHINES["128k"], (
            Poke(TARGETS["logical"], 0, 0x8000, 42),
            Poke(TARGETS["bank"], 6, 0x1234, 99),
        )))
        image[-2] ^= 1
        self.run_loader(bytes(image), MACHINES["128k"], fault=True)


if __name__ == "__main__":
    unittest.main()
