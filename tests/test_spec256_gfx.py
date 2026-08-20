"""Regression tests for the original 48K Spec256 GFX layout."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from tools.spec256.gfx import (  # noqa: E402
    GFX_SIZE,
    PLANE_COUNT,
    RAM_SIZE,
    decode_gfx,
    encode_gfx,
    pixel_colour,
    read_exact_file,
)


class Spec256GfxTests(unittest.TestCase):
    def test_decode_matches_gzx_plane_transposition(self) -> None:
        group = bytes(1 << bit for bit in range(PLANE_COUNT))
        planes = decode_gfx(group * RAM_SIZE)

        self.assertEqual(len(planes), PLANE_COUNT)
        for plane_index, plane in enumerate(planes):
            self.assertEqual(plane, bytes([1 << plane_index]) * RAM_SIZE)

    def test_decode_and_encode_round_trip(self) -> None:
        payload = bytes((index * 37 + 11) & 0xFF for index in range(GFX_SIZE))

        self.assertEqual(encode_gfx(decode_gfx(payload)), payload)

    def test_pixel_colour_reconstructs_eight_planes(self) -> None:
        address = 12_345
        pixel_index = 3
        expected_colour = 0xA6
        source_bit = 7 - pixel_index
        planes = [bytearray(RAM_SIZE) for _ in range(PLANE_COUNT)]
        for plane_index, plane in enumerate(planes):
            if expected_colour & (1 << plane_index):
                plane[address] = 1 << source_bit

        self.assertEqual(
            pixel_colour(tuple(bytes(plane) for plane in planes), address, pixel_index),
            expected_colour,
        )

    def test_pixel_lookup_rejects_invalid_coordinates_and_planes(self) -> None:
        planes = tuple(bytes(RAM_SIZE) for _ in range(PLANE_COUNT))
        with self.assertRaisesRegex(ValueError, "address must be between"):
            pixel_colour(planes, RAM_SIZE, 0)
        with self.assertRaisesRegex(ValueError, "pixel index must be between"):
            pixel_colour(planes, 0, 8)
        with self.assertRaisesRegex(ValueError, "requires eight 48 KiB planes"):
            pixel_colour(planes[:-1], 0, 0)

    def test_wrong_payload_size_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly 393216 bytes"):
            decode_gfx(bytes(GFX_SIZE - 1))

    def test_wrong_plane_shape_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "requires 8 planes"):
            encode_gfx([bytes(RAM_SIZE)] * 7)
        with self.assertRaisesRegex(ValueError, "plane 7 must be exactly"):
            encode_gfx([bytes(RAM_SIZE)] * 7 + [bytes(RAM_SIZE - 1)])

    def test_cli_identifies_a_valid_file_without_modifying_it(self) -> None:
        payload = bytes([0x5A]) * GFX_SIZE
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "TEST.GFX"
            path.write_bytes(payload)
            result = subprocess.run(
                ["python3", str(REPO_ROOT / "tools/spec256/gfx.py"), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bytes: 393216", result.stdout)
        self.assertIn("round-trip-identical: yes", result.stdout)

    def test_exact_reader_rejects_size_before_reading_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "oversized.gfx"
            path.write_bytes(bytes(17))
            with self.assertRaisesRegex(ValueError, "exactly 16 bytes, got 17"):
                read_exact_file(path, 16, "test input")


if __name__ == "__main__":
    unittest.main()
