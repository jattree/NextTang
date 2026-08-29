"""Tests for preparing private Spec256 assets for the FPGA build."""

from pathlib import Path
import tempfile
import unittest

from tools.spec256.gfx import GFX_SIZE
from tools.spec256.hardware import (
    apply_gfx_overrides,
    build_graphical_rom_planes,
    build_lane_memory_planes,
    build_lane_memory_image,
    write_lane_memory,
    write_plane_memories,
    write_graphical_rom_memories,
    write_palette_memory,
)
from tools.spec256.snapshot import RAM_BASE, parse_snapshot
from tests.test_spec256_snapshot import Spec256SnapshotTests


class Spec256HardwareImageTests(unittest.TestCase):
    def snapshot(self):
        return parse_snapshot(Spec256SnapshotTests.fixture())

    def test_non_marker_group_is_transposed_into_eight_lanes(self) -> None:
        snapshot = self.snapshot()
        graphics = bytearray(GFX_SIZE)
        graphics[0:8] = bytes((1, 2, 4, 8, 16, 32, 64, 128))

        planes = apply_gfx_overrides(snapshot, bytes(graphics))

        self.assertEqual(
            tuple(plane[0] for plane in planes),
            (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80),
        )

    def test_zero_and_ff_groups_are_transposed_like_every_other_group(self) -> None:
        snapshot = self.snapshot()
        graphics = bytearray(GFX_SIZE)
        graphics[8:16] = bytes((0xFF,) * 8)

        planes = apply_gfx_overrides(snapshot, bytes(graphics))

        self.assertEqual(tuple(plane[0] for plane in planes), (0x00,) * 8)
        self.assertEqual(tuple(plane[1] for plane in planes), (0xFF,) * 8)

    def test_lane_memory_is_address_aligned_and_lane_zero_is_low_byte(self) -> None:
        snapshot = self.snapshot()
        graphics = bytearray(GFX_SIZE)
        graphics[0:8] = bytes((1, 2, 4, 8, 16, 32, 64, 128))

        image = build_lane_memory_image(snapshot, bytes(graphics))

        self.assertEqual(len(image), 64 * 1024)
        self.assertEqual(image[:RAM_BASE], (0,) * RAM_BASE)
        self.assertEqual(image[RAM_BASE], 0x8040201008040201)

    def test_writer_emits_one_64_bit_hex_word_per_address(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "spec256-ram.mem"
            image = (0, 0x0102040810204080)
            write_lane_memory(destination, image)
            self.assertEqual(
                destination.read_text(encoding="ascii").splitlines(),
                ["0000000000000000", "0102040810204080"],
            )

    def test_plane_images_are_full_addressed_and_independent(self) -> None:
        snapshot = self.snapshot()
        graphics = bytearray(GFX_SIZE)
        graphics[0:8] = bytes((1, 2, 4, 8, 16, 32, 64, 128))

        planes = build_lane_memory_planes(snapshot, bytes(graphics))

        self.assertEqual(len(planes), 8)
        self.assertTrue(all(len(plane) == 48 * 1024 for plane in planes))
        self.assertEqual(tuple(plane[0] for plane in planes),
                         (1, 2, 4, 8, 16, 32, 64, 128))

        with tempfile.TemporaryDirectory() as temporary:
            paths = write_plane_memories(Path(temporary), planes)
            self.assertEqual([path.name for path in paths], [
                f"spec256-plane{lane}.mem" for lane in range(8)
            ])
            self.assertEqual(
                paths[7].read_text(encoding="ascii").splitlines()[0],
                "80",
            )
            self.assertEqual(
                (Path(temporary) / "spec256-plane7-bank0.mem")
                .read_text(encoding="ascii").splitlines()[0],
                "80",
            )

    def test_graphical_rom_is_full_and_transposed_per_lane(self) -> None:
        graphics = bytearray(16 * 1024 * 8)
        graphics[0:8] = bytes(
            (1, 2, 4, 8, 16, 32, 64, 128)
        )

        planes = build_graphical_rom_planes(bytes(graphics))

        self.assertTrue(all(len(plane) == 16 * 1024 for plane in planes))
        self.assertEqual(tuple(plane[0] for plane in planes),
                         (1, 2, 4, 8, 16, 32, 64, 128))

        with tempfile.TemporaryDirectory() as temporary:
            paths = write_graphical_rom_memories(Path(temporary), planes)
            self.assertEqual(paths[0].name, "spec256-rom-plane0.mem")
            self.assertEqual(
                paths[7].read_text(encoding="ascii").splitlines()[0],
                "80",
            )

    def test_palette_writer_emits_one_rgb_word_per_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "sp256.pal"
            destination = root / "spec256-palette.mem"
            values = []
            for index in range(256):
                values.extend((index, 255 - index, index // 2))
            source.write_text(" ".join(str(value) for value in values), encoding="ascii")

            write_palette_memory(source, destination)

            lines = destination.read_text(encoding="ascii").splitlines()
            self.assertEqual(len(lines), 256)
            self.assertEqual(lines[0], "00ff00")
            self.assertEqual(lines[-1], "ff007d")


if __name__ == "__main__":
    unittest.main()
