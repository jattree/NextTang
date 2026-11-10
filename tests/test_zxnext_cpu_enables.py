"""The CPU enable generator must agree with the reference CPU clock rule.

The ZX Next core's CPU runs on clock_28 with enables from
rtl/clock/nexttang_zxnext_cpu_enables.vhd. tests/sim/zxnext/tb_cpu_enables.vhd
drives it with random speed changes, pixel-counter bit and contention, at each
of the four phases the 7 MHz divider can take against 28 MHz, and fails on the
first edge where an enable disagrees with the reference rule in
tests/sim/zxnext/cpu_clock_reference_pkg.vhd.

The full-core comparison, the unmodified core with a real CPU clock against the
converted one, takes minutes per run and is run by
tests/sim/zxnext/run_equivalence.sh rather than here.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    REPO_ROOT / "rtl" / "clock" / "nexttang_zxnext_cpu_enables.vhd",
    REPO_ROOT / "tests" / "sim" / "zxnext" / "cpu_clock_reference_pkg.vhd",
    REPO_ROOT / "tests" / "sim" / "zxnext" / "tb_cpu_enables.vhd",
)
FLAGS = ("--std=08", "-frelaxed")


@unittest.skipUnless(shutil.which("ghdl"), "ghdl is not installed")
class CpuEnablesTest(unittest.TestCase):
    def test_enables_match_reference_at_every_phase(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = f"--workdir={directory}"
            for step in (("-i", *FLAGS, work, *map(str, SOURCES)), ("-m", *FLAGS, work, "tb_cpu_enables")):
                result = subprocess.run(["ghdl", *step], capture_output=True, text=True, cwd=directory)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for phase in range(4):
                with self.subTest(phase=phase):
                    result = subprocess.run(
                        ["ghdl", "-r", *FLAGS, work, "tb_cpu_enables",
                         f"-gPHASE={phase}", f"-gSEED={phase + 11}", "-gCYCLES=60000"],
                        capture_output=True, text=True, cwd=directory,
                    )
                    output = result.stdout + result.stderr
                    self.assertEqual(result.returncode, 0, output)
                    self.assertIn("CPU_ENABLES_PASS", output)


if __name__ == "__main__":
    unittest.main()
