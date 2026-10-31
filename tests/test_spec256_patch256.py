"""tools/spec256/patch256.py must change only the game's own bytes of the text it names.

On a synthetic .256: a rule replaces the game byte of every occurrence it
expects and nothing else (the planes and all other bytes stay); a wrong
occurrence count, a different .256 (sha256), strings of different lengths or
a string split across two banks are refused; the IPS patch it writes gives
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


def put_text(game: bytearray, address: int, text: bytes) -> None:
    for i, byte in enumerate(text):
        game[(address + i) * 9 + 8] = byte


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
        changed = [i for i in range(len(game)) if game[i] != patched[i]]
        self.assertTrue(all(i % 9 == 8 for i in changed))
        self.assertEqual(len(changed), 9 + 6 + 6 - 3)   # trailing spaces replace letters
        self.assertEqual(apply_ips(bytes(game), patch256.ips(bytes(game), patch)), patched)

    def test_refusals(self) -> None:
        game = make_game()
        put_text(game, 200, b"JUGAR")
        put_text(game, 16_384 - 2, b"PAUSA")             # across banks 0 and 1
        good = bytes(game)
        cases = {
            "found 1 times": patch_for(good, '"JUGAR" = "PLAY " x2'),
            "not the one": "sha256: " + "0" * 64 + '\n"JUGAR" = "PLAY "\n',
            "characters": patch_for(good, '"JUGAR" = "PLAY"'),
            "found 0 times": patch_for(good, '"PAUSA" = "PAUSE"'),
        }
        for message, patch in cases.items():
            with self.assertRaises(patch256.PatchError) as raised:
                patch256.apply(good, patch)
            self.assertIn(message, str(raised.exception))

    def test_shipped_patches_keep_lengths(self) -> None:
        patches = sorted((REPO_ROOT / "tools" / "spec256" / "patches").glob("*.txt"))
        self.assertTrue(patches)
        for path in patches:
            header, rules = patch256.read_patch(path.read_text(encoding="utf-8"))
            self.assertIn("sha256", header, path.name)
            self.assertTrue(rules, path.name)


if __name__ == "__main__":
    unittest.main()
