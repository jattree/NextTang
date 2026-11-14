"""Simulations behind the Tang Nano 20K board: the SDR SDRAM service (ports A
and C, and Layer 2 on port B), the I2S transmitter, hdmi_frame's G_RELOCK
option, where HDMI data islands go in hdmi_frame's output, the BL616
FPGA-Companion keyboard target, and the SPI master's late MISO sampling
against an SD card through the Nano's pins."""

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


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class I2sTransmitterTest(unittest.TestCase):
    def test_words_decode_back(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sim.vvp"
            run(["iverilog", "-g2012", "-o", str(image), str(SIM / "audio" / "tb_i2s_transmitter.v"),
                 str(REPO_ROOT / "rtl" / "audio" / "nexttang_i2s_transmitter.v")], REPO_ROOT)
            output = run(["vvp", "-n", str(image)], REPO_ROOT)
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
            # 48K, 128K and Pentagon frame lengths: shorter and longer than the HDMI frame
            for cycles, lines, lock in ((896, 312, 0), (912, 311, 4), (896, 320, 0)):
                output = run(["ghdl", "-r", *flags, "tb_hdmi_frame_relock", "-gRELOCK=true", "-gFRAMES=12",
                              f"-gCORE_CYC={cycles}", f"-gCORE_LINES={lines}", f"-gLOCK_LINE={lock}",
                              "--ieee-asserts=disable"], Path(directory))
                self.assertIn("PASS", output, output)


@unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
class SpiMasterLateMisoTest(unittest.TestCase):
    """tests/sim/zxnext/tb_spi_master.vhd: SCK out through the Nano's I/O
    register and 6.44 ns of pin and board, MISO back in 3.95 ns. The official
    sampling point leaves a card 7.4 ns at 28 MHz (nano20k_zxnext.sdc), so a
    14 ns card (the SD spec's limit) fails there; g_miso_late gives about 25."""

    def test_card_delays_and_cpu_speeds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            flags = ["--std=08", "-frelaxed", "-fsynopsys", f"--workdir={directory}"]
            run(["ghdl", "-a", *flags,
                 str(REPO_ROOT / "rtl" / "serial" / "spi_master.vhd"),
                 str(SIM / "zxnext" / "tb_spi_master.vhd")], REPO_ROOT)
            run(["ghdl", "-e", *flags, "tb_spi_master"], Path(directory))

            def simulate(late: int, divide: int, stretch: bool, card_ps: int) -> str:
                return run(["ghdl", "-r", *flags, "tb_spi_master", f"-gMISO_LATE={late}",
                            f"-gDIVIDE={divide}", f"-gSTRETCH={'true' if stretch else 'false'}",
                            f"-gCARD_PS={card_ps}", "--ieee-asserts=disable"], Path(directory))

            # the official sampling point: a 7 ns card works, a 14 ns one fails at 28 MHz
            self.assertIn("PASS", simulate(0, 1, True, 7000))
            self.assertIn("FAIL", simulate(0, 1, False, 14000))
            # late sampling: a 14 ns card at every CPU speed, with contention; 24 ns at 28 MHz
            for divide in (1, 2, 4, 8):
                output = simulate(1, divide, True, 14000)
                self.assertIn("PASS", output, f"divide {divide}: {output}")
            self.assertIn("PASS", simulate(1, 1, False, 24000))
            self.assertIn("PASS", simulate(1, 1, True, 2000))


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class HdmiIslandTimingTest(unittest.TestCase):
    def test_islands_and_guard_bands(self) -> None:
        # 576p50 and 480p60, the front porch changing every frame as G_RELOCK does
        for video_60 in (0, 1):
            with tempfile.TemporaryDirectory() as directory:
                image = Path(directory) / "sim.vvp"
                run(["iverilog", "-g2005", f"-Ptb_hdmi_island_timing.VIDEO_60={video_60}", "-o", str(image),
                     str(SIM / "video" / "tb_hdmi_island_timing.v"),
                     str(REPO_ROOT / "rtl" / "video" / "nexttang_hdmi_island_timing.v")], REPO_ROOT)
                output = run(["vvp", "-n", str(image)], REPO_ROOT)
                self.assertIn("PASS", output, output)


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class CompanionKeyboardTest(unittest.TestCase):
    def test_status_reply_and_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sim.vvp"
            run(["iverilog", "-g2005", "-o", str(image),
                 str(SIM / "input" / "tb_companion_keyboard.v"),
                 str(REPO_ROOT / "rtl" / "input" / "nexttang_companion_keyboard.v"),
                 str(REPO_ROOT / "rtl" / "input" / "nexttang_ps2_matrix.v")], REPO_ROOT)
            output = run(["vvp", "-n", str(image)], REPO_ROOT)
            self.assertIn("PASS", output, output)


if __name__ == "__main__":
    unittest.main()
