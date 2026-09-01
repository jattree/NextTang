"""Regression tests for the version 2 game pack.

Version 2 exists to carry the two things a run across the whole published
collection needs and version 1 could not express: backgrounds, of which four
games ship more than one, and the absence of a graphical ROM, which nineteen of
thirty-six games have.
"""

from pathlib import Path
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from tools.spec256.gfx import GFX_SIZE  # noqa: E402
from tools.spec256.gamepack import (  # noqa: E402
    BASE_PAYLOAD_SIZE,
    HEADER_SIZE,
    MAX_BACKGROUNDS,
    VERSION,
    build_gamepack,
    default_graphical_rom_planes,
    parse_gamepack,
    payload_size_for,
)
from tools.spec256.hardware import ROM_GFX_SIZE, ROM_SIZE  # noqa: E402
from tools.spec256.render import BACKGROUND_SIZE  # noqa: E402
from tools.spec256.snapshot import RAM_SIZE, SNA_HEADER_SIZE  # noqa: E402


def write(directory: Path, name: str, payload: bytes) -> Path:
    path = directory / name
    path.write_bytes(payload)
    return path


def minimal_snapshot() -> bytes:
    """A 48K SNA whose stacked PC is inside RAM, which the bootstrap needs."""
    ram = bytearray(RAM_SIZE)
    stack = 0xFF00
    ram[stack - 0x4000 : stack - 0x4000 + 2] = (0x8000).to_bytes(2, "little")
    header = bytearray(SNA_HEADER_SIZE)
    header[23:25] = stack.to_bytes(2, "little")
    header[25] = 1
    return bytes(header + ram)


def palette_text() -> bytes:
    return (" ".join(["0"] * (256 * 3))).encode("ascii")


class GamePackV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self._directory = tempfile.TemporaryDirectory()
        root = Path(self._directory.name)
        self.snapshot = write(root, "game.sna", minimal_snapshot())
        self.gfx = write(root, "game.gfx", bytes(GFX_SIZE))
        self.rom_gfx = write(root, "rom0.gfx", bytes(ROM_GFX_SIZE))
        self.rom = write(root, "48.rom", bytes(index & 0xff for index in range(ROM_SIZE)))
        self.palette = write(root, "sp256.pal", palette_text())
        self.root = root

    def tearDown(self) -> None:
        self._directory.cleanup()

    def background(self, name: str, fill: int) -> Path:
        return write(self.root, name, bytes([fill]) * BACKGROUND_SIZE)

    def test_pack_without_backgrounds_keeps_the_version_one_length(self) -> None:
        image = build_gamepack(self.snapshot, self.gfx, self.rom_gfx, self.palette)

        self.assertEqual(len(image), HEADER_SIZE + BASE_PAYLOAD_SIZE)
        pack = parse_gamepack(image)
        self.assertEqual(pack.version, VERSION)
        self.assertEqual(pack.background_count, 0)
        self.assertEqual(pack.backgrounds, ())

    def test_backgrounds_are_carried_in_index_order(self) -> None:
        sources = [self.background(f"game.b0{i}", 0x10 + i) for i in range(3)]

        image = build_gamepack(
            self.snapshot, self.gfx, self.rom_gfx, self.palette, backgrounds=sources
        )

        pack = parse_gamepack(image)
        self.assertEqual(pack.background_count, 3)
        self.assertEqual(len(image), HEADER_SIZE + payload_size_for(3))
        for index, background in enumerate(pack.backgrounds):
            self.assertEqual(set(background), {0x10 + index})

    def test_missing_graphical_rom_leaves_the_rom_in_ordinary_colours(self) -> None:
        """Nineteen games ship none; their execution planes clone the ROM."""
        image = build_gamepack(
            self.snapshot, self.gfx, None, self.palette, rom_source=self.rom
        )

        pack = parse_gamepack(image)
        start = 16 * 1024 + RAM_SIZE + 8 * RAM_SIZE
        rom_region = pack.payload[start : start + 8 * ROM_SIZE]
        expected = self.rom.read_bytes() * 8
        self.assertEqual(rom_region, expected)
        self.assertEqual(default_graphical_rom_planes(self.rom.read_bytes()),
                         tuple(self.rom.read_bytes() for _ in range(8)))

    def test_missing_graphical_rom_requires_the_ordinary_rom(self) -> None:
        with self.assertRaisesRegex(ValueError, "48K ROM is required"):
            build_gamepack(self.snapshot, self.gfx, None, self.palette)

    def test_a_supplied_graphical_rom_is_not_replaced_by_the_default(self) -> None:
        image = build_gamepack(self.snapshot, self.gfx, self.rom_gfx, self.palette)

        pack = parse_gamepack(image)
        start = 16 * 1024 + RAM_SIZE + 8 * RAM_SIZE
        rom_region = pack.payload[start : start + 8 * ROM_SIZE]
        self.assertEqual(set(rom_region), {0x00})

    def test_a_graphical_rom_with_a_trailer_is_accepted(self) -> None:
        """Chuckie Egg and Ruff and Reddy ship 134,672-byte files.

        GZX reads 16384 groups of eight from the start and ignores the rest, and
        the leading 131,072 bytes are the ones that decode correctly, so the
        trailer is discarded rather than refused.
        """
        long_rom = write(
            self.root, "long_rom0.gfx",
            bytes(ROM_GFX_SIZE) + b"\xa5" * 3600,
        )

        image = build_gamepack(self.snapshot, self.gfx, long_rom, self.palette)

        pack = parse_gamepack(image)
        start = 16 * 1024 + RAM_SIZE + 8 * RAM_SIZE
        rom_region = pack.payload[start : start + 8 * ROM_SIZE]
        self.assertEqual(set(rom_region), {0x00}, "the trailer reached the planes")

    def test_a_short_graphical_rom_is_still_refused(self) -> None:
        short = write(self.root, "short_rom0.gfx", bytes(ROM_GFX_SIZE - 1))

        with self.assertRaisesRegex(ValueError, "at least 131072"):
            build_gamepack(self.snapshot, self.gfx, short, self.palette)

    def test_background_count_and_payload_size_must_agree(self) -> None:
        """A count that does not match the length is a corrupt pack, not a hint."""
        image = bytearray(
            build_gamepack(
                self.snapshot, self.gfx, self.rom_gfx, self.palette,
                backgrounds=[self.background("game.b00", 0x22)],
            )
        )
        image[HEADER_SIZE - 1] = 2  # claim two backgrounds, carry one

        with self.assertRaisesRegex(ValueError, "unexpected Spec256 payload size"):
            parse_gamepack(bytes(image))

    def test_more_backgrounds_than_the_format_allows_is_refused(self) -> None:
        sources = [
            self.background(f"game.b{i:02d}", i) for i in range(MAX_BACKGROUNDS + 1)
        ]

        with self.assertRaisesRegex(ValueError, "at most 8 backgrounds"):
            build_gamepack(
                self.snapshot, self.gfx, self.rom_gfx, self.palette,
                backgrounds=sources,
            )

    def test_a_wrong_sized_background_is_refused(self) -> None:
        short = write(self.root, "short.b00", bytes(BACKGROUND_SIZE - 1))

        with self.assertRaisesRegex(ValueError, "64000"):
            build_gamepack(
                self.snapshot, self.gfx, self.rom_gfx, self.palette,
                backgrounds=[short],
            )

    def test_the_crc_covers_the_backgrounds(self) -> None:
        image = bytearray(
            build_gamepack(
                self.snapshot, self.gfx, self.rom_gfx, self.palette,
                backgrounds=[self.background("game.b00", 0x33)],
            )
        )
        image[-1] ^= 0xFF

        with self.assertRaisesRegex(ValueError, "CRC mismatch"):
            parse_gamepack(bytes(image))


if __name__ == "__main__":
    unittest.main()
