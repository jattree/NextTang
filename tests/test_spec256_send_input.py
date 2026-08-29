"""Host-side framing for live Spec256 runtime controls."""

import unittest

from tools.spec256.send_input import encode_joystick, encode_key


class Spec256SendInputTests(unittest.TestCase):
    def test_key_press_and_release_use_spectrum_matrix_index(self) -> None:
        self.assertEqual(encode_key("5", pressed=True), b"K\x13\x01")
        self.assertEqual(encode_key("space", pressed=False), b"K\x23\x00")

    def test_joystick_combines_kempston_controls(self) -> None:
        self.assertEqual(encode_joystick(("right", "up", "fire")), b"J\x19")
        self.assertEqual(encode_joystick(("neutral",)), b"J\x00")

    def test_invalid_or_opposing_controls_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown Kempston control"):
            encode_joystick(("jump",))
        with self.assertRaisesRegex(ValueError, "opposing horizontal"):
            encode_joystick(("left", "right"))


if __name__ == "__main__":
    unittest.main()
