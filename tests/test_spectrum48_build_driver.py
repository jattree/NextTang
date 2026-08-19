"""Contract tests for the Console 138K Spectrum 48K build driver."""

from pathlib import Path
import subprocess
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_DRIVER = REPO_ROOT / "boards" / "console138k" / "build_spectrum48.sh"


class Spectrum48BuildDriverTests(unittest.TestCase):
    def run_driver(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(BUILD_DRIVER), *arguments],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_help_lists_release_and_ula_profiles(self) -> None:
        result = self.run_driver("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--profile release|ula", result.stdout)

    def test_rejects_relative_output_before_running_vendor_tools(self) -> None:
        result = self.run_driver(
            "--toolchain",
            "vendor",
            "--profile",
            "ula",
            "--output",
            "relative/output",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--output must be an absolute path", result.stderr)

    def test_ula_manifest_hashes_textually_included_top(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn('hash_files=("${source_files[@]}")', source)
        self.assertIn(
            'hash_files+=(\n'
            '        "$repo_root/boards/console138k/'
            'nexttang_console138k_spectrum48.v"',
            source,
        )
        self.assertIn('sha256sum "${hash_files[@]}"', source)

    def test_driver_pins_exact_console_device_and_checks_timing(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn(
            "set_device -device_version C GW5AST-LV138PG484AC1/I0",
            source,
        )
        self.assertIn("scripts/check_timing.py", source)


if __name__ == "__main__":
    unittest.main()
