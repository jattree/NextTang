"""tools/spec256/patch256.py must change only the text it names, all nine bytes of each character.

On a synthetic .256: a rule replaces every byte (eight planes and the game's
byte) of every character of every occurrence it expects, and nothing else; a
wrong occurrence count, a different .256 (sha256), strings of different
lengths, a string split across two banks, or text whose planes are not its
code eight times (colour data) are refused; the IPS patch it writes gives
the same file as applying it directly. The shipped patches parse and keep
every string's length.
"""

from __future__ import annotations

import hashlib
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "spec256"))
import patch256  # noqa: E402

SIZE = 8 * 16_384 * 9


def make_game() -> bytearray:
    game = bytearray((i * 7) & 0xFF for i in range(SIZE + 200))
    for i in range(8 * 16_384):
        game[i * 9 + 8] = 0
    return game


def put_text(game: bytearray, address: int, text: bytes, planes: bool = True) -> None:
    for i, byte in enumerate(text):
        record = (address + i) * 9
        game[record + 8] = byte
        if planes:
            game[record:record + 8] = bytes((byte,)) * 8


def patch_for(game: bytes, rules: str) -> str:
    return f"game: Test\nsha256: {hashlib.sha256(game).hexdigest()}\n{rules}\n"


def apply_ips(game: bytes, patch: bytes) -> bytes:
    out = bytearray(game)
    i = 5
    while patch[i:i + 3] != b"EOF":
        offset = int.from_bytes(patch[i:i + 3], "big")
        size = int.from_bytes(patch[i + 3:i + 5], "big")
        out[offset:offset + size] = patch[i + 5:i + 5 + size]
        i += 5 + size
    return bytes(out)


class Patch256Test(unittest.TestCase):
    def test_replaces_only_the_game_bytes_of_the_text(self) -> None:
        game = make_game()
        put_text(game, 5 * 16_384 + 100, b"1-TECLADO")
        put_text(game, 0 * 16_384 + 50, b"FUEGO-1")
        put_text(game, 3 * 16_384 + 7, b"FUEGO-1")
        patch = patch_for(bytes(game), '"1-TECLADO" = "1-KEYS   "\n"FUEGO-1" = "FIRE-1 " x2')
        patched = patch256.apply(bytes(game), patch)
        memory = patch256.game_bytes(patched)
        self.assertEqual(memory[5 * 16_384 + 100:5 * 16_384 + 109], b"1-KEYS   ")
        self.assertEqual(memory[50:57], b"FIRE-1 ")
        self.assertEqual(memory[3 * 16_384 + 7:3 * 16_384 + 14], b"FIRE-1 ")
        for address, text in ((5 * 16_384 + 100, b"1-KEYS   "), (50, b"FIRE-1 "), (3 * 16_384 + 7, b"FIRE-1 ")):
            for i, byte in enumerate(text):
                self.assertEqual(patched[(address + i) * 9:(address + i + 1) * 9], bytes((byte,)) * 9)
        changed = [i for i in range(len(game)) if game[i] != patched[i]]
        self.assertEqual(len(changed), 9 * (6 + 6 + 6))   # "1-", the E of KEYS and "F" stay
        self.assertEqual(apply_ips(bytes(game), patch256.ips(bytes(game), patch)), patched)

    def test_refusals(self) -> None:
        game = make_game()
        put_text(game, 200, b"JUGAR")
        put_text(game, 16_384 - 2, b"PAUSA")             # across banks 0 and 1
        put_text(game, 900, b"SUBIR", planes=False)       # colour data, not text
        good = bytes(game)
        cases = {
            "found 1 times": patch_for(good, '"JUGAR" = "PLAY " x2'),
            "not the one": "sha256: " + "0" * 64 + '\n"JUGAR" = "PLAY "\n',
            "characters": patch_for(good, '"JUGAR" = "PLAY"'),
            "found 0 times": patch_for(good, '"PAUSA" = "PAUSE"'),
            "not plain text": patch_for(good, '"SUBIR" = "UP   "'),
        }
        for message, patch in cases.items():
            with self.assertRaises(patch256.PatchError) as raised:
                patch256.apply(good, patch)
            self.assertIn(message, str(raised.exception))

    def test_label_takes_colour_from_the_old_picture(self) -> None:
        game = make_game()
        game[patch256.REGISTERS_AT + 28] = 0x30           # 48K: bank 0 at 0xC000
        # Old picture at 0x8100 (bank 2), 2 bytes x 1 row: pixels 0-2 a letter
        # coloured 5, 6, 7; the rest index 1. All nine bits per pixel.
        old = [(1, 5), (1, 6), (1, 7)] + [(0, 1)] * 13
        for c in range(2):
            record = [0] * 9
            for b in range(8):
                master, index = old[c * 8 + b]
                for k in range(8):
                    record[k] |= ((index >> k) & 1) << (7 - b)
                record[8] |= master << (7 - b)
            at = (2 * 16_384 + 0x100 + c) * 9
            game[at:at + 9] = bytes(record)
        # New picture: the letter moved to pixels 8-10, a new one at 13-14.
        patch = patch_for(bytes(game), "label: 8100 2 1\npixels: 00e6\n"
                                       "take: 8-10 0-2\nshade: 12-15 9 10\nbackground: 1")
        patched = patch256.apply(bytes(game), patch)
        pixels = []
        for c in range(2):
            record = patched[(2 * 16_384 + 0x100 + c) * 9:][:9]
            for b in range(8):
                pixels.append((record[8] >> (7 - b) & 1, sum(((record[k] >> (7 - b)) & 1) << k for k in range(8))))
        self.assertEqual(pixels[8:11], [(1, 5), (1, 6), (1, 7)])
        self.assertEqual(pixels[13:15], [(1, 9), (1, 10)])
        self.assertEqual([p for i, p in enumerate(pixels) if i not in (8, 9, 10, 13, 14)], [(0, 1)] * 11)
        wrong = patch_for(bytes(game), "label: 8100 2 1\npixels: 00f0\ntake: 8-11 0-3\nbackground: 1")
        with self.assertRaises(patch256.PatchError):
            patch256.apply(bytes(game), wrong)

    def test_shipped_patches_keep_lengths(self) -> None:
        patches = sorted((REPO_ROOT / "tools" / "spec256" / "patches").glob("*.txt"))
        self.assertTrue(patches)
        for path in patches:
            header, rules = patch256.read_patch(path.read_text(encoding="utf-8"))
            self.assertIn("sha256", header, path.name)
            self.assertTrue(rules, path.name)


if __name__ == "__main__":
    unittest.main()
