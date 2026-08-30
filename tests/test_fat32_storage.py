"""Structural contracts for the complete read-only FAT32 storage service."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    REPO_ROOT / "rtl/storage/nexttang_spi_byte_master.v",
    REPO_ROOT / "rtl/storage/nexttang_sd_spi_reader.v",
    REPO_ROOT / "rtl/storage/nexttang_fat32_volume.v",
    REPO_ROOT / "rtl/storage/nexttang_fat32_cluster_stream.v",
    REPO_ROOT / "rtl/storage/nexttang_fat32_directory_entry.v",
    REPO_ROOT / "rtl/storage/nexttang_fat32_directory.v",
    REPO_ROOT / "rtl/storage/nexttang_fat32_storage.v",
]


class Fat32StorageTests(unittest.TestCase):
    def test_complete_stack_elaborates_and_has_no_write_interface(self) -> None:
        source = SOURCES[-1].read_text(encoding="utf-8")
        self.assertIn("nexttang_sd_spi_reader", source)
        self.assertIn("nexttang_fat32_volume", source)
        self.assertIn("nexttang_fat32_directory", source)
        self.assertIn("nexttang_fat32_cluster_stream", source)
        self.assertNotIn("write_start", source)
        self.assertNotIn("sd_write", source)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "storage.vvp"
            result = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "nexttang_fat32_storage",
                 "-o", str(output), *(str(item) for item in SOURCES)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
