"""Contract tests for the Console 138K DDR3 build driver."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_DRIVER = REPO_ROOT / "boards" / "console138k" / "build_ddr3.sh"


class Console138kDdr3BuildDriverTests(unittest.TestCase):
    def run_driver(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(BUILD_DRIVER), *arguments],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_help_documents_external_vendor_source(self) -> None:
        result = self.run_driver("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--vendor-source ABSOLUTE_DIRECTORY", result.stdout)
        self.assertIn("--profile diagnostic|logo|spec256", result.stdout)
        self.assertIn("--image ABSOLUTE_RGB332_MEM", result.stdout)

    def test_rejects_relative_directories_before_running_vendor_tools(self) -> None:
        result = self.run_driver(
            "--toolchain",
            "vendor",
            "--profile",
            "diagnostic",
            "--vendor-source",
            "relative/vendor",
            "--output",
            "relative/output",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--vendor-source must be an absolute path", result.stderr)

    def test_rejects_missing_generated_vendor_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            vendor_source = root / "vendor"
            output = root / "output"
            vendor_source.mkdir()
            output.mkdir()

            result = self.run_driver(
                "--toolchain",
                "vendor",
                "--profile",
                "diagnostic",
                "--vendor-source",
                str(vendor_source),
                "--output",
                str(output),
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("required vendor source missing", result.stderr)
        self.assertNotIn("gw_sh", result.stderr)

    def test_driver_pins_exact_device_and_acceptance_evidence(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn(
            "set_device -device_version C GW5AST-LV138PG484AC1/I0",
            source,
        )
        self.assertIn("vendor-source-sha256.txt", source)
        self.assertIn("build-manifest.txt", source)
        # The driver must reject a build that violates timing. It calls the
        # shared checker rather than carrying its own copy of the parsing.
        self.assertIn("scripts/check_timing.py", source)
        self.assertIn("nexttang_console138k_ddr3_logo", source)
        self.assertIn("nexttang_ddr3_logo_engine.v", source)

    def test_logo_profile_reaches_vendor_source_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            vendor_source = root / "vendor"
            output = root / "output"
            vendor_source.mkdir()
            output.mkdir()

            result = self.run_driver(
                "--toolchain",
                "vendor",
                "--profile",
                "logo",
                "--vendor-source",
                str(vendor_source),
                "--output",
                str(output),
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("required vendor source missing", result.stderr)

    def test_spec256_profile_requires_an_absolute_image(self) -> None:
        result = self.run_driver(
            "--toolchain",
            "vendor",
            "--profile",
            "spec256",
            "--vendor-source",
            "/tmp/vendor",
            "--output",
            "/tmp/output",
            "--image",
            "relative/frame.mem",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--image must be an absolute path", result.stderr)

    def test_spec256_profile_reaches_vendor_validation_with_valid_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            vendor_source = root / "vendor"
            output = root / "output"
            image = root / "frame.mem"
            vendor_source.mkdir()
            output.mkdir()
            image.write_text("00\n" * (256 * 192), encoding="ascii")

            result = self.run_driver(
                "--toolchain",
                "vendor",
                "--profile",
                "spec256",
                "--vendor-source",
                str(vendor_source),
                "--output",
                str(output),
                "--image",
                str(image),
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("required vendor source missing", result.stderr)

    def test_spec256_profile_retargets_internal_constraints_for_wrapper(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")

        self.assertIn('constraint_prefix="display/"', source)
        self.assertIn("console138k_ddr3_spec256.cst", source)
        self.assertIn("console138k_ddr3_spec256.sdc", source)
        self.assertIn("${constraint_prefix}memory_pll/", source)
        self.assertIn("${constraint_prefix}ddr3/", source)
        self.assertIn("${constraint_prefix}pixel_clock_divider/", source)
        self.assertIn(
            "get_nets {${constraint_prefix}memory_clock}",
            source,
        )
        self.assertNotIn('s|{memory_clock}|', source)


if __name__ == "__main__":
    unittest.main()
