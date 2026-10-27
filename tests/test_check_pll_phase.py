"""The PLL phase check has to catch a phase that no longer matches the SDC.

clock_28_n sat at 194 degrees under a 180 degree constraint for two months
because the PLL counts phase in VCO periods and the divider changed under it.
The check must pass the board's own files, fail that setting, and fail rather
than pass when the SDC or the PLL is missing what it needs.
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "check_pll_phase.py"
SPEC = importlib.util.spec_from_file_location("check_pll_phase", SCRIPT)
assert SPEC and SPEC.loader
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

SDC = """create_clock -name clock_28 -period 35.714 [get_pins {clock_tree/machine_pll/pll/CLKOUT0}]
create_clock -name clock_28_n -period 35.714 -waveform {17.857 35.714} [get_pins {clock_tree/machine_pll/pll/CLKOUT3}]
"""

PLL = """    defparam pll.ODIV0_SEL = 25;
    defparam pll.ODIV3_SEL = {divider_3};
    defparam pll.CLKOUT3_PE_COARSE = {coarse};
    defparam pll.CLKOUT3_PE_FINE = 4;
"""


class PllPhaseCheck(unittest.TestCase):
    def problems(self, coarse=12, divider_3=25, sdc=SDC) -> list[str]:
        return check.phase_problems(sdc, PLL.format(coarse=coarse, divider_3=divider_3))

    def test_half_period_passes(self) -> None:
        self.assertEqual(self.problems(), [])

    def test_setting_left_from_the_old_divider_fails(self) -> None:
        # 13 + 4/8 was 180 degrees against 27 and is 194 against 25.
        self.assertEqual(len(self.problems(coarse=13)), 1)

    def test_different_divider_fails(self) -> None:
        self.assertEqual(len(self.problems(divider_3=50)), 1)

    def test_missing_clock_fails(self) -> None:
        with self.assertRaises(LookupError):
            self.problems(sdc=SDC.splitlines()[0] + "\n")

    def test_board_files_agree(self) -> None:
        board = REPO_ROOT / "boards" / "console138k"
        pll = (board / "nexttang_console138k_machine_pll.v").read_text()
        for sdc in ("console138k_zxnext.sdc", "console138k_zxnext_ddr3.sdc"):
            with self.subTest(sdc=sdc):
                self.assertEqual(check.phase_problems((board / sdc).read_text(), pll), [])


if __name__ == "__main__":
    unittest.main()
