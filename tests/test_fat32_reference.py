"""Read-only FAT32/LFN reference parser tests."""

import io
from pathlib import Path
import struct
import sys
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools/storage"))
from fat32 import Fat32Volume  # noqa: E402


def short_checksum(name: bytes) -> int:
    value = 0
    for byte in name:
        value = ((((value & 1) << 7) | (value >> 1)) + byte) & 0xFF
    return value


def lfn_entries(name: str, short: bytes) -> list[bytes]:
    units = [ord(character) for character in name] + [0]
    while len(units) % 13:
        units.append(0xFFFF)
    checksum = short_checksum(short)
    result = []
    count = len(units) // 13
    for ordinal in range(count, 0, -1):
        chunk = units[(ordinal - 1) * 13:ordinal * 13]
        entry = bytearray(b"\xff" * 32)
        entry[0] = ordinal | (0x40 if ordinal == count else 0)
        entry[11] = 0x0F; entry[12] = 0; entry[13] = checksum
        entry[26:28] = b"\0\0"
        encoded = b"".join(struct.pack("<H", unit) for unit in chunk)
        entry[1:11], entry[14:26], entry[28:32] = encoded[:10], encoded[10:22], encoded[22:]
        result.append(bytes(entry))
    return result


class Fat32ReferenceTests(unittest.TestCase):
    def test_fragmented_file_and_valid_lfn(self) -> None:
        image = bytearray(12 * 512)
        image[510:512] = b"\x55\xaa"
        image[450] = 0x0C
        struct.pack_into("<I", image, 454, 1)
        boot = memoryview(image)[512:1024]
        struct.pack_into("<H", boot, 11, 512); boot[13] = 1
        struct.pack_into("<H", boot, 14, 1); boot[16] = 1
        struct.pack_into("<I", boot, 36, 1); struct.pack_into("<I", boot, 44, 2)
        boot[510:512] = b"\x55\xaa"
        fat = memoryview(image)[1024:1536]
        for cluster, following in ((0, 0x0FFFFFF8), (1, 0x0FFFFFFF),
                                   (2, 0x0FFFFFFF), (3, 0x0FFFFFFF),
                                   (4, 6), (6, 0x0FFFFFFF)):
            struct.pack_into("<I", fat, cluster * 4, following)

        root = memoryview(image)[1536:2048]
        root[:11] = b"GAMES      "; root[11] = 0x10
        struct.pack_into("<H", root, 26, 3)
        games = memoryview(image)[2048:2560]
        short = b"JETPAC~1TAP"
        entries = lfn_entries("Jet Pac Deluxe.tap", short)
        cursor = 0
        for entry in entries:
            games[cursor:cursor + 32] = entry; cursor += 32
        games[cursor:cursor + 11] = short; games[cursor + 11] = 0x20
        struct.pack_into("<H", games, cursor + 26, 4)
        payload = bytes((index * 7) & 0xFF for index in range(700))
        struct.pack_into("<I", games, cursor + 28, len(payload))
        image[2560:3072] = payload[:512]
        image[3584:3584 + len(payload) - 512] = payload[512:]

        with Fat32Volume(io.BytesIO(image)) as volume:
            directory = volume.find("/games")
            self.assertTrue(directory.is_directory)
            game = volume.find("/GAMES/jet pac deluxe.tap")
            self.assertEqual(game.short_name, "JETPAC~1.TAP")
            self.assertEqual(volume.read_file(game), payload)


if __name__ == "__main__":
    unittest.main()
