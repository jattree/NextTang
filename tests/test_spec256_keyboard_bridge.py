"""Host-keyboard behaviour for the live Spec256 UART bridge."""

from __future__ import annotations

import sys
import unittest
from unittest import mock

from tools.spec256 import keyboard_bridge
from tools.spec256.gamepack import SPECTRUM_KEY_INDICES


def key_frame(name: str, pressed: bool) -> bytes:
    return bytes((ord("K"), SPECTRUM_KEY_INDICES[name], int(pressed)))


class Spec256KeyboardBridgeTests(unittest.TestCase):
    def run_events(self, events: list[tuple[int, int]]) -> list[bytes]:
        """Run the real bridge loop with synthetic evdev key events."""
        payload = b"".join(
            keyboard_bridge.EVENT.pack(0, 0, keyboard_bridge.EV_KEY, code, value)
            for code, value in [*events, (1, 1)]  # ESC exits through cleanup.
        )
        writes: list[bytes] = []

        def record_write(descriptor: int, data: bytes) -> int:
            if descriptor == 11:
                writes.append(bytes(data))
            return len(data)

        with (
            mock.patch.object(sys, "argv", ["keyboard_bridge"]),
            mock.patch.object(keyboard_bridge, "find_keyboard", return_value="/dev/fake"),
            mock.patch.object(keyboard_bridge.os, "open", side_effect=[10, 11]),
            mock.patch.object(keyboard_bridge, "configure_serial"),
            mock.patch.object(keyboard_bridge.select, "select", return_value=([10], [], [])),
            mock.patch.object(keyboard_bridge.os, "read", return_value=payload),
            mock.patch.object(keyboard_bridge.os, "write", side_effect=record_write),
            mock.patch.object(keyboard_bridge.os, "close"),
            mock.patch.object(keyboard_bridge.termios, "tcdrain"),
            mock.patch("builtins.print"),
        ):
            self.assertEqual(keyboard_bridge.main(), 0)
        return writes

    def test_backspace_sends_caps_shift_zero_chord(self) -> None:
        self.assertEqual(
            self.run_events([(14, 1), (14, 0)]),
            [
                key_frame("CAPS SHIFT", True),
                key_frame("0", True),
                key_frame("0", False),
                key_frame("CAPS SHIFT", False),
                b"J\x00",
            ],
        )

    def test_control_is_symbol_shift_not_joystick_fire(self) -> None:
        self.assertEqual(
            self.run_events([(29, 1), (29, 0)]),
            [
                key_frame("SYMBOL SHIFT", True),
                key_frame("SYMBOL SHIFT", False),
                b"J\x00",
            ],
        )

    def test_duplicate_modifier_does_not_release_until_both_keys_are_up(self) -> None:
        self.assertEqual(
            self.run_events([(29, 1), (97, 1), (29, 0)]),
            [
                key_frame("SYMBOL SHIFT", True),
                key_frame("SYMBOL SHIFT", False),
                b"J\x00",
            ],
        )

    def test_duplicate_fire_key_does_not_clear_while_one_alt_is_held(self) -> None:
        self.assertEqual(
            self.run_events([(56, 1), (100, 1), (56, 0)]),
            [b"J\x10", b"J\x00"],
        )

    def test_arrow_keys_send_complete_kempston_state(self) -> None:
        self.assertEqual(
            self.run_events([(106, 1), (103, 1), (106, 0), (103, 0)]),
            [b"J\x01", b"J\x09", b"J\x08", b"J\x00", b"J\x00"],
        )

    def test_evdev_auto_repeat_is_ignored(self) -> None:
        self.assertEqual(
            self.run_events([(30, 1), (30, 2), (30, 0)]),
            [key_frame("A", True), key_frame("A", False), b"J\x00"],
        )

    def test_autodetect_skips_usb_consumer_control_pseudo_keyboard(self) -> None:
        devices = """\
I: Bus=0003 Vendor=046d Product=085e Version=0111
N: Name="Logitech BRIO Consumer Control"
H: Handlers=kbd event4

I: Bus=0003 Vendor=258a Product=0049 Version=0111
N: Name="BY Tech Gaming Keyboard"
H: Handlers=sysrq kbd leds event8

I: Bus=0011 Vendor=0001 Product=0001 Version=ab83
N: Name="AT Translated Set 2 keyboard"
H: Handlers=sysrq kbd leds event3
"""
        with (
            mock.patch.object(
                keyboard_bridge.Path,
                "read_text",
                return_value=devices,
            ),
            mock.patch.object(keyboard_bridge.os, "access", return_value=True),
            mock.patch("builtins.print"),
        ):
            self.assertEqual(keyboard_bridge.find_keyboard(None), "/dev/input/event8")


if __name__ == "__main__":
    unittest.main()
