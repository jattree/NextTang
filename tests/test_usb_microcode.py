"""The USB host microcode ROM must be what its committed source assembles to."""

import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
UKP_DIR = REPO_ROOT / "rtl" / "input" / "ukp"
ROM = REPO_ROOT / "rtl" / "input" / "usb_hid_host_rom.mem"


class UsbMicrocodeTest(unittest.TestCase):
    def test_rom_matches_assembled_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            shutil.copy(UKP_DIR / "ukp.s", work)
            shutil.copy(UKP_DIR / "asukp.py", work)
            result = subprocess.run(
                [sys.executable, "-I", "asukp.py"],
                cwd=work,
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            assembled = (work / "usb_hid_host_rom.mem").read_text()
            self.assertEqual(assembled, ROM.read_text())
            # The ROM holds 1024 nibbles.
            self.assertLessEqual(len(assembled.split()), 1024)
            # The enumeration trace recognises branches to connerr by address.
            listing = (work / "ukp.lst").read_text()
            label = re.search(r"^([0-9a-f]{4})\s+connerr:", listing, re.MULTILINE)
            self.assertIsNotNone(label)
            rtl = (REPO_ROOT / "rtl" / "input" / "usb_hid_host.v").read_text()
            parameter = re.search(r"CONNERR_ADDR = 10'h([0-9a-f]+)", rtl)
            self.assertIsNotNone(parameter)
            self.assertEqual(int(label.group(1), 16), int(parameter.group(1), 16))


if __name__ == "__main__":
    unittest.main()
