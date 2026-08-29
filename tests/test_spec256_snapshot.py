"""Regression tests for loading a 48K SNA into the hardware core."""

from pathlib import Path
import tempfile
import unittest

from tools.spec256.snapshot import (
    RAM_BASE,
    SNA_SIZE,
    build_bootstrap,
    build_ram_image,
    convert_snapshot,
    parse_snapshot,
)


class Spec256SnapshotTests(unittest.TestCase):
    @staticmethod
    def fixture() -> bytes:
        header = bytearray(27)
        header[0] = 0xB2
        header[1:3] = bytes((0x58, 0x27))
        header[3:5] = bytes((0x9B, 0x36))
        header[5:7] = bytes((0xCC, 0x9C))
        header[7:9] = bytes((0x65, 0x21))
        header[9:11] = bytes((0xE1, 0x58))
        header[11:13] = bytes((0x78, 0xCA))
        header[13:15] = bytes((0x2B, 0x00))
        header[15:17] = bytes((0x3A, 0x5C))
        header[17:19] = bytes((0xD2, 0x03))
        header[19] = 0x04
        header[20] = 0x64
        header[21:23] = bytes((0x28, 0x00))
        header[23:25] = bytes((0x38, 0xFF))
        header[25] = 2
        header[26] = 3

        ram = bytearray(48 * 1024)
        ram[0] = 0xA5
        ram[1] = 0x5A
        stack = 0xFF38 - RAM_BASE
        ram[stack : stack + 2] = bytes((0x9C, 0x9C))
        return bytes(header + ram)

    def test_parses_pc_and_register_state_from_48k_snapshot(self) -> None:
        snapshot = parse_snapshot(self.fixture())
        self.assertEqual(len(self.fixture()), SNA_SIZE)
        self.assertEqual(snapshot.pc, 0x9C9C)
        self.assertEqual(snapshot.sp, 0xFF38)
        self.assertEqual(snapshot.af, 0x0028)
        self.assertEqual(snapshot.af_alt, 0x2165)
        self.assertEqual(snapshot.im, 2)
        self.assertTrue(snapshot.iff2)

    def test_builds_full_addressed_ram_and_restoring_bootstrap(self) -> None:
        snapshot = parse_snapshot(self.fixture())
        ram = build_ram_image(snapshot)
        bootstrap = build_bootstrap(snapshot)

        self.assertEqual(len(ram), 64 * 1024)
        self.assertEqual(ram[:RAM_BASE], bytes(RAM_BASE))
        self.assertEqual(ram[RAM_BASE : RAM_BASE + 2], bytes((0xA5, 0x5A)))
        self.assertEqual(ram[0xFF38 : 0xFF3A], bytes((0x9C, 0x9C)))
        self.assertEqual(bootstrap[-1], 0xC9)  # RET through the saved PC
        self.assertIn(bytes((0x31, 0x38, 0xFF)), bootstrap)
        self.assertIn(bytes((0x36, 0xA5, 0x23, 0x36, 0x5A)), bootstrap)

    def test_rejects_snapshot_with_stack_outside_48k_ram(self) -> None:
        broken = bytearray(self.fixture())
        broken[23:25] = bytes((0x00, 0x20))
        with self.assertRaisesRegex(ValueError, "stack pointer"):
            parse_snapshot(bytes(broken))

    def test_converter_writes_only_build_inputs_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "GAME.SNA"
            ram = root / "snapshot-ram.mem"
            boot = root / "snapshot-boot.mem"
            manifest = root / "snapshot-input-sha256.txt"
            source.write_bytes(self.fixture())

            convert_snapshot(source, ram, boot, manifest)

            self.assertEqual(len(ram.read_text().splitlines()), 64 * 1024)
            self.assertGreater(len(boot.read_text().splitlines()), 1)
            self.assertIn("GAME.SNA", manifest.read_text())


if __name__ == "__main__":
    unittest.main()
