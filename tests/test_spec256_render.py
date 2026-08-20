"""Regression tests for the software Spec256 reference renderer."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from tools.spec256.gfx import GFX_SIZE, PLANE_COUNT, RAM_SIZE  # noqa: E402
from tools.spec256.render import (  # noqa: E402
    BACKGROUND_PAPER_X,
    BACKGROUND_PAPER_Y,
    BACKGROUND_SIZE,
    BACKGROUND_WIDTH,
    MAX_PALETTE_BYTES,
    PAPER_HEIGHT,
    PAPER_WIDTH,
    load_palette,
    render_paper_indices,
    spectrum_screen_offset,
    write_ppm,
    write_rgb332_mem,
)


class Spec256RenderTests(unittest.TestCase):
    def test_spectrum_screen_layout_matches_ula_addressing(self) -> None:
        self.assertEqual(spectrum_screen_offset(0, 0), 0x0000)
        self.assertEqual(spectrum_screen_offset(1, 0), 0x0100)
        self.assertEqual(spectrum_screen_offset(7, 31), 0x071F)
        self.assertEqual(spectrum_screen_offset(8, 0), 0x0020)
        self.assertEqual(spectrum_screen_offset(64, 0), 0x0800)

    def test_screen_layout_rejects_invalid_coordinates(self) -> None:
        with self.assertRaisesRegex(ValueError, "line must be between"):
            spectrum_screen_offset(PAPER_HEIGHT, 0)
        with self.assertRaisesRegex(ValueError, "byte column must be between"):
            spectrum_screen_offset(0, PAPER_WIDTH // 8)

    def test_nonzero_shadow_pixel_overrides_background(self) -> None:
        planes = [bytearray(RAM_SIZE) for _ in range(PLANE_COUNT)]
        expected_colour = 0xA6
        for plane_index, plane in enumerate(planes):
            if expected_colour & (1 << plane_index):
                plane[0] = 0x80
        background = bytes([0x31]) * BACKGROUND_SIZE

        output = render_paper_indices(
            tuple(bytes(plane) for plane in planes), background
        )

        self.assertEqual(output[0], expected_colour)
        self.assertEqual(output[1], 0x31)

    def test_zero_shadow_pixel_uses_centred_background_paper(self) -> None:
        planes = tuple(bytes(RAM_SIZE) for _ in range(PLANE_COUNT))
        background = bytearray(BACKGROUND_SIZE)
        offset = BACKGROUND_PAPER_Y * BACKGROUND_WIDTH + BACKGROUND_PAPER_X
        background[offset] = 0x73

        output = render_paper_indices(planes, bytes(background))

        self.assertEqual(output[0], 0x73)

    def test_palette_reproduces_gzx_six_bit_quantisation(self) -> None:
        values = []
        for index in range(256):
            values.extend((index, 255 - index, index // 2))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.pal"
            path.write_text(" ".join(str(value) for value in values), encoding="ascii")
            palette = load_palette(path)

        self.assertEqual(len(palette), 256)
        self.assertEqual(palette[0], (0, 255, 0))
        self.assertEqual(palette[255], (255, 0, 125))

    def test_ppm_writer_checks_dimensions(self) -> None:
        palette = tuple((index, index, index) for index in range(256))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.ppm"
            write_ppm(path, 2, 1, bytes((1, 2)), palette)
            output = path.read_bytes()

        self.assertEqual(output, b"P6\n2 1\n255\n\x01\x01\x01\x02\x02\x02")

    def test_wrong_background_size_is_rejected(self) -> None:
        planes = tuple(bytes(RAM_SIZE) for _ in range(PLANE_COUNT))
        with self.assertRaisesRegex(ValueError, "exactly 64000 bytes"):
            render_paper_indices(planes, bytes(BACKGROUND_SIZE - 1))

    def test_renderer_rejects_wrong_plane_shape(self) -> None:
        with self.assertRaisesRegex(ValueError, "requires eight 48 KiB planes"):
            render_paper_indices(tuple(bytes(RAM_SIZE) for _ in range(7)))

    def test_palette_rejects_wrong_values_and_unbounded_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            short = root / "short.pal"
            short.write_text("0 1 2", encoding="ascii")
            with self.assertRaisesRegex(ValueError, "must contain 768 values"):
                load_palette(short)

            out_of_range = root / "range.pal"
            out_of_range.write_text("256 " + "0 " * 767, encoding="ascii")
            with self.assertRaisesRegex(ValueError, "between 0 and 255"):
                load_palette(out_of_range)

            oversized = root / "oversized.pal"
            oversized.write_bytes(bytes(MAX_PALETTE_BYTES + 1))
            with self.assertRaisesRegex(ValueError, "must be no larger"):
                load_palette(oversized)

    def test_ppm_writer_rejects_wrong_palette_size(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.ppm"
            with self.assertRaisesRegex(ValueError, "256-entry palette"):
                write_ppm(path, 1, 1, b"\x00", ((0, 0, 0),))

    def test_rgb332_writer_quantises_palette_and_checks_its_size(self) -> None:
        palette = [(0, 0, 0)] * 256
        palette[1] = (255, 128, 64)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.mem"
            write_rgb332_mem(path, bytes((0, 1)), tuple(palette))
            output = path.read_text(encoding="ascii")

            self.assertEqual(output, "00\nf1\n")
            with self.assertRaisesRegex(ValueError, "256-entry palette"):
                write_rgb332_mem(path, b"\x00", ((0, 0, 0),))

    def test_cli_can_emit_rgb332_memory_initialisation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gfx = root / "TEST.GFX"
            palette = root / "sp256.pal"
            output = root / "test.mem"
            gfx.write_bytes(bytes(GFX_SIZE))
            palette.write_text("0 " * (256 * 3), encoding="ascii")

            result = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "tools/spec256/render.py"),
                    str(gfx),
                    "--palette",
                    str(palette),
                    "--output-format",
                    "rgb332-mem",
                    "--output",
                    str(output),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(output.read_text(encoding="ascii").splitlines()), 49152)

    def test_renderer_runs_directly_from_repository_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gfx = root / "TEST.GFX"
            background = root / "TEST.B00"
            palette = root / "sp256.pal"
            output = root / "test.ppm"
            gfx.write_bytes(bytes(GFX_SIZE))
            background.write_bytes(bytes(BACKGROUND_SIZE))
            palette.write_text("0 " * (256 * 3), encoding="ascii")

            result = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "tools/spec256/render.py"),
                    str(gfx),
                    "--background",
                    str(background),
                    "--palette",
                    str(palette),
                    "--output",
                    str(output),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(output.is_file())


if __name__ == "__main__":
    unittest.main()
