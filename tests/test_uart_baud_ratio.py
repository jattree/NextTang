"""The UART receiver must refuse a clock too slow for its baud rate.

The behavioural tests run the receiver at ten clocks per bit, which is
comfortable, so they cannot see that a deployed instantiation is parameterised
somewhere it can never work.  That is how the BL616 keyboard link shipped at
3.5 MHz against 2 Mbaud: 1.75 real clocks per bit while the receiver counts 2,
so the sampling point walks 2.5 bit-times across one frame and nothing decodes.

Elaboration is the only place that catches it, because the parameters are fixed
there and nowhere else.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RECEIVER = REPO_ROOT / "rtl" / "input" / "nexttang_uart_receiver.v"
TOP = REPO_ROOT / "boards" / "console138k" / "nexttang_console138k_spectrum48.v"


def elaborates(clock_hz: int, baud_rate: int) -> tuple[bool, str]:
    body = f"""
module tb;
    wire [7:0] data;
    wire data_valid;
    nexttang_uart_receiver #(.CLOCK_HZ({clock_hz}), .BAUD_RATE({baud_rate})) dut (
        .clock(1'b0), .reset(1'b1), .receive(1'b1),
        .data(data), .data_valid(data_valid));
endmodule
"""
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "tb.v"
        source.write_text(body, encoding="ascii")
        result = subprocess.run(
            ["iverilog", "-g2012", "-o", "/dev/null", "-s", "tb",
             str(RECEIVER), str(source)],
            capture_output=True, text=True, check=False,
        )
    return result.returncode == 0, result.stderr


class UartBaudRatioTests(unittest.TestCase):
    def test_the_ratio_that_shipped_is_refused(self) -> None:
        ok, stderr = elaborates(3_500_000, 2_000_000)

        self.assertFalse(ok, "3.5 MHz against 2 Mbaud must not elaborate")
        self.assertIn("clock_too_slow_for_this_baud_rate", stderr)

    def test_the_corrected_ratio_is_accepted(self) -> None:
        ok, _ = elaborates(28_000_000, 2_000_000)

        self.assertTrue(ok, "28 MHz against 2 Mbaud is 14 clocks per bit")

    def test_the_pack_and_status_link_is_accepted(self) -> None:
        """230400 from 3.5 MHz is 15.2 clocks per bit and must keep working."""
        ok, _ = elaborates(3_500_000, 230_400)

        self.assertTrue(ok)

    def test_the_boundary_is_where_it_is_documented(self) -> None:
        self.assertTrue(elaborates(8 * 115_200, 115_200)[0])
        self.assertFalse(elaborates(7 * 115_200, 115_200)[0])

    def test_the_bl616_link_is_not_parameterised_from_the_cpu_clock(self) -> None:
        """Guard the call site too, so the ratio cannot regress silently."""
        source = TOP.read_text(encoding="utf-8")
        start = source.index("nexttang_bl616_keyboard #(")
        block = source[start : start + 400]

        self.assertIn("CLOCK_HZ(28000000)", block)
        self.assertIn("clock(clock_28)", block)


if __name__ == "__main__":
    unittest.main()
