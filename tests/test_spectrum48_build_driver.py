"""Contract tests for the Console 138K Spectrum 48K build driver."""

from pathlib import Path
import subprocess
import tempfile
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

    def test_help_lists_all_profiles(self) -> None:
        result = self.run_driver("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "--profile release|ula|ula-tape|ula-ddr-upper|ula-ddr-upper-tape",
            result.stdout,
        )

    def test_ddr_profile_requires_explicit_vendor_source(self) -> None:
        result = self.run_driver(
            "--toolchain",
            "vendor",
            "--profile",
            "ula-ddr-upper",
            "--output",
            "/tmp/nexttang-unused-build-output",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --vendor-source ABSOLUTE_DIRECTORY", result.stderr)

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

    def test_ddr_profile_combines_constraints_and_hashes_vendor_inputs(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn("console138k_spectrum48_ula_ddr3_extra.cst", source)
        self.assertIn('>"$pin_constraints"', source)
        self.assertIn('printf \'add_file {%s}\\n\' "$pin_constraints"', source)
        self.assertIn("vendor-source-sha256.txt", source)

    def test_tape_profile_requires_absolute_user_supplied_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            vendor = root / "vendor"
            for relative in (
                "ddr3_memory_interface/ddr3_memory_interface.v",
                "gowin_pll/gowin_pll.v",
                "gowin_pll/gowin_pll_mod.v",
                "pll_init.v",
            ):
                path = vendor / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// test\n", encoding="utf-8")

            result = self.run_driver(
                "--toolchain",
                "vendor",
                "--profile",
                "ula-ddr-upper-tape",
                "--vendor-source",
                str(vendor),
                "--tape",
                "relative/Cobra.tzx",
                "--output",
                str(root / "unused"),
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --tape ABSOLUTE_TZX_OR_ZIP", result.stderr)

    def test_internal_ram_tape_profile_needs_a_tape_but_no_vendor_source(
        self,
    ) -> None:
        # The control for the DDR tape target takes the same user tape without
        # any generated vendor memory controller, so it must fail on a missing
        # tape rather than on a missing vendor source.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.run_driver(
                "--toolchain",
                "vendor",
                "--profile",
                "ula-tape",
                "--output",
                str(root / "unused"),
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --tape ABSOLUTE_TZX_OR_ZIP", result.stderr)

    def test_tape_profile_records_converter_and_input_manifest(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn("scripts/tzx_to_mem.py", source)
        self.assertIn("tape-input-sha256.txt", source)
        self.assertIn("nexttang_tzx_player.v", source)
        self.assertIn(
            "nexttang_console138k_spectrum48_ula_ddr3_tape.v",
            source,
        )

    def test_driver_pins_exact_console_device_and_checks_timing(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn(
            "set_device -device_version C GW5AST-LV138PG484AC1/I0",
            source,
        )
        self.assertIn("scripts/check_timing.py", source)


if __name__ == "__main__":
    unittest.main()
