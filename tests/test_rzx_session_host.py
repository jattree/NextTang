"""host/rzx_session.py: the parts that need no board."""

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "host"))
import rzx_session  # noqa: E402


class RzxSessionHostTest(unittest.TestCase):
    def test_script_is_sorted_by_time(self) -> None:
        self.assertEqual(rzx_session.parse_script("8:R3, 5:K0000000020,20:Q"),
                         [(5.0, "K0000000020"), (8.0, "R3"), (20.0, "Q")])

    def test_script_refuses_what_it_does_not_know(self) -> None:
        for bad in ("5:K12", "5:R", "5:X", "5:Q1"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                rzx_session.parse_script(bad)

    def test_rewind_ends_the_stream_with_the_handover_code(self) -> None:
        # FE 02, not rzx_play.py's FE 01: the board starts the recorder and
        # stops the CPU where the replay ends (rtl/debug/nexttang_rzx_play_link.v).
        source = (REPO_ROOT / "host/rzx_session.py").read_text()
        self.assertIn(r'b"\xff\xff\x00" + b"\xfe\x02"', source)


if __name__ == "__main__":
    unittest.main()
