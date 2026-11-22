"""Simulations behind the Tang Nano 20K board: the SDR SDRAM service (ports A
and C, and Layer 2 on port B), the I2S transmitter, hdmi_frame's G_RELOCK
option, where HDMI data islands go in hdmi_frame's output, the BL616
FPGA-Companion keyboard target, and the SPI master's late MISO sampling
against an SD card through the Nano's pins."""

import os
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
        # with the word cache at each size, and without it
        for words in (4, 2, 0):
            with self.subTest(word_cache=words):
                output = self.iverilog(SIM / "sdram" / "tb_sdr_sdram_service.v", {"ACCESSES": 4000, "WORD_CACHE": words})
                self.assertIn("PASS", output, output)
                self.assertEqual(", 0 reads from the cache" in output, words == 0, output)

    def port_c_handover(self, gate: int) -> str:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sim.vvp"
            run(["iverilog", "-g2012", "-s", "tb", f"-Ptb.GATE={gate}", "-o", str(image),
                 str(SIM / "sdram" / "tb_port_c_handover.v"), str(SERVICE),
                 str(REPO_ROOT / "rtl" / "platform" / "nexttang_next_machine.v")], REPO_ROOT)
            return run(["vvp", "-n", str(image)], REPO_ROOT)

    def test_port_c_handover(self) -> None:
        # the ring lets go of port C with the debug slave's request waiting
        self.assertIn("PASS", self.port_c_handover(1))

    def test_port_c_handover_bench_catches_the_fault(self) -> None:
        self.assertIn("never acked", self.port_c_handover(0))

    @unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
    def test_sprite_line_buffer_banks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for step in (["ghdl", "-a", "--std=08", str(REPO_ROOT / "rtl" / "core" / "memory" / "nexttang_sdpram.vhd"),
                          str(SIM / "video" / "tb_spram_320_9.vhd")],
                         ["ghdl", "-e", "--std=08", "tb_spram_320_9"],
                         ["ghdl", "-r", "--std=08", "tb_spram_320_9"]):
                result = subprocess.run(step, cwd=directory, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout + result.stderr)

    def test_hdmi_packet_assembler_matches_original(self) -> None:
        suite = os.environ.get("NEXTTANG_OSS_CAD_SUITE", "/opt/oss-cad-suite/2026-08-05")
        verilator = shutil.which("verilator") or shutil.which("verilator", path=str(Path(suite) / "bin"))
        if not verilator:
            self.skipTest("verilator not installed")
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, PATH=str(Path(verilator).parent) + os.pathsep + os.environ["PATH"])
            build = subprocess.run([verilator, "--binary", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style",
                                    "--top-module", "tb", "-Mdir", directory,
                                    str(SIM / "video" / "tb_packet_assembler.sv"),
                                    str(REPO_ROOT / "rtl" / "video" / "hdmi" / "packet_assembler.sv"),
                                    str(SIM / "video" / "packet_assembler_ref.sv")],
                                   cwd=directory, capture_output=True, text=True, env=env)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(Path(directory) / "Vtb")], capture_output=True, text=True)
            self.assertIn("PASS", result.stdout, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
    def test_pi_debug_reads_at_4_5_mhz(self) -> None:
        # the Pi debug slave answers main-memory reads correctly up to 4.5 MHz
        with tempfile.TemporaryDirectory() as directory:
            steps = (["ghdl", "-a", "--std=08", "-fsynopsys", str(REPO_ROOT / "rtl" / "serial" / "spi_slave.vhd"),
                      str(REPO_ROOT / "rtl" / "device" / "pi_debug_control" / "pi_debug_control_param.vhd"),
                      str(SIM / "debug" / "tb_pi_spi_rate.vhd")],
                     ["ghdl", "-e", "--std=08", "-fsynopsys", "tb_pi_spi_rate"])
            for step in steps:
                result = subprocess.run(step, cwd=directory, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for hz in (2000000, 4500000):
                result = subprocess.run(["ghdl", "-r", "--std=08", "-fsynopsys", "tb_pi_spi_rate",
                                         f"-gSCLK_HZ={hz}", "-gREADS=20"], cwd=directory, capture_output=True, text=True)
                self.assertIn("PASS", result.stdout + result.stderr, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("ghdl"), "ghdl not installed")
    def test_internal_spi_master_at_3_5_mhz(self) -> None:
        # the FPGA's own SPI master reads the debug slave correctly at the
        # board's setting (HALF_CLOCKS 4) and one step faster
        with tempfile.TemporaryDirectory() as directory:
            steps = (["ghdl", "-a", "--std=08", "-fsynopsys", str(REPO_ROOT / "rtl" / "serial" / "spi_slave.vhd"),
                      str(REPO_ROOT / "rtl" / "debug" / "nexttang_pi_spi_master.vhd"),
                      str(REPO_ROOT / "rtl" / "device" / "pi_debug_control" / "pi_debug_control_param.vhd"),
                      str(SIM / "debug" / "tb_internal_spi_master.vhd")],
                     ["ghdl", "-e", "--std=08", "-fsynopsys", "tb_internal_spi_master"])
            for step in steps:
                result = subprocess.run(step, cwd=directory, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for half in (4, 3):
                result = subprocess.run(["ghdl", "-r", "--std=08", "-fsynopsys", "tb_internal_spi_master",
                                         f"-gHALF_CLOCKS={half}", "-gREADS=15"], cwd=directory, capture_output=True, text=True)
                self.assertIn("PASS", result.stdout + result.stderr, result.stdout + result.stderr)

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
                 str(REPO_ROOT / "rtl" / "input" / "nexttang_usb_keyboard_matrix.v")], REPO_ROOT)
            output = run(["vvp", "-n", str(image)], REPO_ROOT)
            self.assertIn("PASS", output, output)



@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class RtcTest(unittest.TestCase):
    def test_i2c_uart_set_and_rollovers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sim.vvp"
            run(["iverilog", "-g2005", "-o", str(image),
                 str(SIM / "peripherals" / "tb_rtc.v"),
                 str(REPO_ROOT / "rtl" / "peripherals" / "nexttang_rtc.v")], REPO_ROOT)
            output = run(["vvp", "-n", str(image)], REPO_ROOT)
            self.assertIn("PASS", output, output)



GOWIN_PRIMITIVES = Path("/opt/gowin/1.9.12.03/simlib/gw2a/prim_sim.v")


def alu54d_model(directory: str) -> Path:
    """Gowin's own ALU54D model, cut out of its simulation library (not kept in the repository)."""
    text = GOWIN_PRIMITIVES.read_text()
    start = text.index("module ALU54D")
    model = Path(directory) / "alu54d.v"
    model.write_text(text[start:text.index("endmodule", start) + len("endmodule")] + "\n")
    return model


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp") and GOWIN_PRIMITIVES.exists(),
                     "iverilog or the Gowin simulation library not installed")
class DspBlockFormsTest(unittest.TestCase):
    """Modules with a DSP-block form must behave as their ordinary form does."""

    def test_audio_pcm_samples_equal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "sim.vvp"
            run(["iverilog", "-g2005", "-o", str(image),
                 str(SIM / "audio" / "tb_audio_pcm_dsp_equal.v"),
                 str(REPO_ROOT / "rtl" / "audio" / "nexttang_zxnext_audio_pcm.v"),
                 str(alu54d_model(directory))], REPO_ROOT)
            output = run(["vvp", "-n", str(image)], REPO_ROOT)
            self.assertIn("PASS", output, output)

    def test_rtc_with_dsp_prescaler(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bench = Path(directory) / "tb_rtc_dsp.v"
            bench.write_text((SIM / "peripherals" / "tb_rtc.v").read_text().replace(
                "CLOCK_HZ(20000)", "CLOCK_HZ(20000), .DSP_PRESCALER(1)") + "\nmodule GSR; wire GSRO = 1'b1; endmodule\n")
            image = Path(directory) / "sim.vvp"
            run(["iverilog", "-g2005", "-o", str(image), str(bench),
                 str(REPO_ROOT / "rtl" / "peripherals" / "nexttang_rtc.v"),
                 str(alu54d_model(directory))], REPO_ROOT)
            output = run(["vvp", "-n", str(image)], REPO_ROOT)
            self.assertIn("PASS", output, output)


if __name__ == "__main__":
    unittest.main()
