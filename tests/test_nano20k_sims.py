"""Simulations behind the Tang Nano 20K board: the SDR SDRAM service (ports A
and C, and Layer 2 on port B) and hdmi_frame's G_RELOCK option."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
SERVICE = REPO_ROOT / "rtl" / "memory" / "nexttang_sdr_sdram_service.v"
SIM = REPO_ROOT / "tests" / "sim"


def run(command: list[str], cwd: Path) -> str:
    result = subprocess.run(command, cwd=cwd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"{' '.join(command)} failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class SdrSdramServiceTest(unittest.TestCase):
    def iverilog(self, testbench: Path, parameters: dict[str, int]) -> str:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sim.vvp"
            flags = [f"-Ptb.{name}={value}" for name, value in parameters.items()]
            run(["iverilog", "-g2012", *flags, "-o", str(image), str(testbench), str(SERVICE)], REPO_ROOT)
            return run(["vvp", "-n", str(image)], REPO_ROOT)

    def test_ports_a_and_c(self) -> None:
        output = self.iverilog(SIM / "sdram" / "tb_sdr_sdram_service.v", {"ACCESSES": 4000})
        self.assertIn("PASS", output, output)

    def test_layer2_rows(self) -> None:
        output = self.iverilog(SIM / "sdram" / "tb_sdr_layer2.v", {"MODE": 0, "LINES": 24, "INJECT_LINE": 10})
        self.assertIn("PASS", output, output)

    def test_layer2_columns(self) -> None:
        output = self.iverilog(SIM / "sdram" / "tb_sdr_layer2.v", {"MODE": 1, "LINES": 24, "INJECT_LINE": 10})
        self.assertIn("PASS", output, output)


@unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
class HdmiFrameRelockTest(unittest.TestCase):
    def test_relock_holds_the_picture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            flags = ["--std=08", "-frelaxed", "-fsynopsys", f"--workdir={directory}"]
            run(["ghdl", "-a", *flags,
                 str(REPO_ROOT / "rtl" / "core" / "memory" / "nexttang_dpram2.vhd"),
                 str(REPO_ROOT / "rtl" / "video" / "hdmi_frame.vhd"),
                 str(SIM / "video" / "tb_hdmi_frame_relock.vhd")], REPO_ROOT)
            run(["ghdl", "-e", *flags, "tb_hdmi_frame_relock"], Path(directory))
            output = run(["ghdl", "-r", *flags, "tb_hdmi_frame_relock", "-gRELOCK=true", "-gFRAMES=7",
                          "--ieee-asserts=disable"], Path(directory))
            self.assertIn("PASS", output, output)


if __name__ == "__main__":
    unittest.main()
