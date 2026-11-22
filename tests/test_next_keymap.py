"""host/next_keymap.py writes a Next keymap file through NextREGs 0x28-0x2B as the firmware does."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("next_keymap", REPO_ROOT / "host" / "next_keymap.py")
next_keymap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(next_keymap)


class Recorder:
    def __init__(self) -> None:
        self.writes: list[tuple[int, int]] = []

    def set_nextreg(self, register: int, value: int) -> None:
        self.writes.append((register, value))


class NextKeymapTest(unittest.TestCase):
    def test_writes_the_whole_map_in_order(self) -> None:
        data = bytes(range(256)) * 4
        debug = Recorder()
        next_keymap.load(debug, data)
        self.assertEqual(debug.writes[:2], [(0x28, 0x00), (0x29, 0x00)])
        body = debug.writes[2:]
        self.assertEqual(len(body), 1024)
        self.assertEqual([r for r, _ in body], [0x2A, 0x2B] * 512)
        self.assertEqual(bytes(v for _, v in body), data)

    def test_refuses_a_short_file(self) -> None:
        with self.assertRaises(ValueError):
            next_keymap.load(Recorder(), bytes(10))

    def test_uk_keys(self) -> None:
        data = next_keymap.with_uk_keys(bytes(1024))
        self.assertEqual(data[2 * 0x5D + 1], 0x9A)   # SYMBOL SHIFT + 3: '#'
        self.assertEqual(data[2 * 0x61 + 1], 0x8A)   # SYMBOL SHIFT + D: '\'
        self.assertEqual(sum(1 for b in data if b), 2)


if __name__ == "__main__":
    unittest.main()
