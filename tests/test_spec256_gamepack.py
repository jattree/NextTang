"""Contracts for the private runtime-loadable Spec256 game-pack format."""

from pathlib import Path
import tempfile
import unittest

from tests import test_spec256_snapshot as snapshot_tests
from tools.spec256.gamepack import (
    HEADER_SIZE,
    MAGIC,
    BASE_PAYLOAD_SIZE,
    VERSION,
    build_gamepack,
    parse_gamepack,
)
from tools.spec256.gfx import GFX_SIZE
from tools.spec256.hardware import ROM_GFX_SIZE


class Spec256GamePackTests(unittest.TestCase):
    def inputs(self, root: Path) -> tuple[Path, Path, Path, Path]:
        snapshot = root / "GAME.sna"
        graphics = root / "GAME.gfx"
        rom_graphics = root / "ROM0.GFX"
        palette = root / "sp256.pal"

        snapshot.write_bytes(snapshot_tests.Spec256SnapshotTests.fixture())
        graphics.write_bytes(bytes(index & 0xFF for index in range(GFX_SIZE)))
        rom_graphics.write_bytes(
            bytes((index * 3) & 0xFF for index in range(ROM_GFX_SIZE))
        )
        palette.write_text(
            " ".join(str(index & 0xFF) for index in range(256 * 3)),
            encoding="ascii",
        )
        return snapshot, graphics, rom_graphics, palette

    def test_builds_one_bounded_crc_checked_runtime_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.inputs(Path(temporary))
            image = build_gamepack(
                *paths,
                keys=("S", "1"),
                start_delay_ms=2000,
                hold_ms=140,
                gap_ms=4000,
            )

        decoded = parse_gamepack(image)
        self.assertEqual(image[:8], MAGIC)
        self.assertEqual(decoded.version, VERSION)
        self.assertEqual(decoded.header_size, HEADER_SIZE)
        self.assertEqual(len(decoded.payload), BASE_PAYLOAD_SIZE)
        self.assertEqual(decoded.key_indices, (6, 15))
        self.assertEqual(decoded.start_delay_ms, 2000)
        self.assertEqual(decoded.hold_ms, 140)
        self.assertEqual(decoded.gap_ms, 4000)

    def test_crc_rejects_a_corrupted_game_before_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image = bytearray(build_gamepack(*self.inputs(Path(temporary))))
        image[-1] ^= 0x80

        with self.assertRaisesRegex(ValueError, "CRC"):
            parse_gamepack(bytes(image))

    def test_unknown_or_excess_launch_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inputs = self.inputs(Path(temporary))
            with self.assertRaisesRegex(ValueError, "Spectrum key"):
                build_gamepack(*inputs, keys=("F12",))
            with self.assertRaisesRegex(ValueError, "at most four"):
                build_gamepack(*inputs, keys=("1", "2", "3", "4", "5"))


if __name__ == "__main__":
    unittest.main()
