"""The timing checker has to fail a violating build and pass a clean one.

This test exists because the check it replaced did neither reliably. It read the
report for any negative number, and clock skew is reported per path and is
routinely negative, so it failed builds that met timing. A checker nobody
verifies is worse than no checker: it trains you to ignore it.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_timing.py"
SPEC = importlib.util.spec_from_file_location("check_timing", SCRIPT)
assert SPEC and SPEC.loader
check_timing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_timing)


# Both report forms Gowin produces, cut down to the fields the checker reads.
# The negative clock skew is the detail that broke the previous check.
HTML_REPORT = """<html><body>
<tr><td>Numbers of Setup Violated Endpoints</td><td>{setup}</td></tr>
<tr><td>Numbers of Hold Violated Endpoints</td><td>{hold}</td></tr>
<tr><td>Setup Analysis Report</td></tr>
<tr><td>Report Command:report_timing -setup -max_paths 25</td></tr>
<tr><td>{setup_slack}</td><td>-0.022</td></tr>
<tr><td>Hold Analysis Report</td></tr>
<tr><td>Report Command:report_timing -hold -max_paths 25</td></tr>
<tr><td>{hold_slack}</td><td>-0.310</td></tr>
</body></html>"""

# The leading lines are the text report's table of contents, which repeats every
# section heading before any of them have content. A parser that keys on the
# heading alone reads the wrong section's slack here.
TEXT_REPORT = """\t\t3.3.1 Setup Paths Table
\t\t3.3.2 Hold Paths Table
Setup Delay Model Slow 0.873V 0C C1/I0

<Numbers of Setup Violated Endpoints>:{setup}
<Numbers of Hold Violated Endpoints>:{hold}

3.1.1 Setup Paths Table
<Report Command>:report_timing -setup -max_paths 25 -max_common_paths 1
  Path Number   Path Slack   Clock Skew
 ============= ============ ===========
  1             {setup_slack}      -0.022
  2             261.487      0.069

3.1.2 Hold Paths Table
<Report Command>:report_timing -hold -max_paths 25
  Path Number   Path Slack   Clock Skew
 ============= ============ ===========
  1             {hold_slack}      -0.310
"""

class CheckTimingTests(unittest.TestCase):
    def run_on(self, body: str, suffix: str) -> tuple[bool, list[str]]:
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / f"report{suffix}"
            report.write_text(body, encoding="utf-8")
            return check_timing.check(report)

    def test_a_clean_build_passes_despite_negative_clock_skew(self) -> None:
        # The exact case the previous check got wrong.
        for body, suffix in ((HTML_REPORT, ".html"), (TEXT_REPORT, ".tr")):
            with self.subTest(suffix=suffix):
                passed, messages = self.run_on(
                    body.format(setup=0, hold=0,
                                setup_slack="259.399", hold_slack="0.246"),
                    suffix)
                self.assertTrue(passed, messages)

    def test_a_violating_build_fails(self) -> None:
        for body, suffix in ((HTML_REPORT, ".html"), (TEXT_REPORT, ".tr")):
            with self.subTest(suffix=suffix):
                passed, messages = self.run_on(
                    body.format(setup=73, hold=11,
                                setup_slack="-11.481", hold_slack="-0.603"),
                    suffix)
                self.assertFalse(passed, messages)
                self.assertTrue(any("73 endpoints violated" in m for m in messages),
                                messages)

    def test_both_report_forms_read_the_same_slack(self) -> None:
        # The two forms are parsed differently, so agreement is what shows the
        # text parser is reading a slack and not some other number near it.
        values = {"setup": 0, "hold": 0,
                  "setup_slack": "259.399", "hold_slack": "0.246"}
        _, html_messages = self.run_on(HTML_REPORT.format(**values), ".html")
        _, text_messages = self.run_on(TEXT_REPORT.format(**values), ".tr")
        self.assertEqual(html_messages, text_messages)
        self.assertIn("259.399 ns", html_messages[0])

    def test_a_report_without_the_verdict_field_fails(self) -> None:
        # A report the checker cannot read must not be reported as passing.
        passed, messages = self.run_on("<html>nothing useful</html>", ".html")
        self.assertFalse(passed, messages)

    def test_a_missing_report_fails_rather_than_passing_quietly(self) -> None:
        # A build that produced no report has not been shown to meet timing.
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "absent.html"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(missing)],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("no report", result.stdout)

    def test_the_command_exits_non_zero_on_a_violating_report(self) -> None:
        # The build scripts act on the exit status, so it is worth testing that
        # path and not only the function behind it.
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "report.html"
            report.write_text(
                HTML_REPORT.format(setup=73, hold=11,
                                   setup_slack="-11.481", hold_slack="-0.603"),
                encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(report)],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1, result.stdout)


if __name__ == "__main__":
    unittest.main()
