"""Tests for the asset-free Spec256 conformance fixture."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from tools.spec256.conformance import (  # noqa: E402
    DESTINATION_ADDRESS,
    LD_COPY_PROGRAM,
    PROGRAM_ADDRESS,
    RAM_BASE,
    SNA_HEADER_SIZE,
    SOURCE_ADDRESS,
    SOURCE_PLANE_BYTES,
    STACK_ADDRESS,
    build_ld_copy_fixture,
    expected_ld_copy_planes,
    ram_offset,
)
from tools.spec256.gfx import GFX_SIZE, RAM_SIZE, decode_gfx  # noqa: E402
from tools.spec256.render import render_paper_indices  # noqa: E402


class Spec256ConformanceTests(unittest.TestCase):
    def test_ram_offset_checks_48k_range(self) -> None:
        self.assertEqual(ram_offset(RAM_BASE), 0)
        self.assertEqual(ram_offset(0xFFFF), RAM_SIZE - 1)
        with self.assertRaisesRegex(ValueError, "between 0x4000 and 0xffff"):
            ram_offset(RAM_BASE - 1)

    def test_ld_copy_fixture_has_valid_sna_and_gfx_shapes(self) -> None:
        snapshot, graphics = build_ld_copy_fixture()

        self.assertEqual(len(snapshot), SNA_HEADER_SIZE + RAM_SIZE)
        self.assertEqual(len(graphics), GFX_SIZE)
        self.assertEqual(snapshot[23:25], STACK_ADDRESS.to_bytes(2, "little"))
        self.assertEqual(snapshot[25], 1)

        ram = snapshot[SNA_HEADER_SIZE:]
        self.assertEqual(
            ram[ram_offset(PROGRAM_ADDRESS) : ram_offset(PROGRAM_ADDRESS) + 7],
            LD_COPY_PROGRAM,
        )
        self.assertEqual(
            ram[ram_offset(STACK_ADDRESS) : ram_offset(STACK_ADDRESS) + 2],
            PROGRAM_ADDRESS.to_bytes(2, "little"),
        )

    def test_each_graphical_plane_fetches_the_same_program(self) -> None:
        _, graphics = build_ld_copy_fixture()
        planes = decode_gfx(graphics)
        program_offset = ram_offset(PROGRAM_ADDRESS)

        for plane in planes:
            self.assertEqual(
                plane[program_offset : program_offset + len(LD_COPY_PROGRAM)],
                LD_COPY_PROGRAM,
            )
        self.assertEqual(
            tuple(plane[ram_offset(SOURCE_ADDRESS)] for plane in planes),
            SOURCE_PLANE_BYTES,
        )

    def test_expected_copy_produces_eight_distinct_pixel_indices(self) -> None:
        _, graphics = build_ld_copy_fixture()
        final_planes = expected_ld_copy_planes(graphics)
        paper = render_paper_indices(final_planes)

        self.assertEqual(tuple(paper[:8]), (1, 2, 4, 8, 16, 32, 64, 128))
        self.assertEqual(
            tuple(
                plane[ram_offset(DESTINATION_ADDRESS)] for plane in final_planes
            ),
            SOURCE_PLANE_BYTES,
        )

    def test_cli_writes_only_the_named_synthetic_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_directory = Path(temporary) / "fixture"
            result = subprocess.run(
                [
                    "python3",
                    str(REPO_ROOT / "tools/spec256/conformance.py"),
                    str(output_directory),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            names = sorted(path.name for path in output_directory.iterdir())

        self.assertEqual(names, ["LD_COPY.GFX", "LD_COPY.SNA"])

    def test_cli_refuses_to_overwrite_an_existing_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_directory = Path(temporary) / "fixture"
            command = [
                "python3",
                str(REPO_ROOT / "tools/spec256/conformance.py"),
                str(output_directory),
            ]
            first = subprocess.run(
                command,
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            snapshot_before = (output_directory / "LD_COPY.SNA").read_bytes()
            second = subprocess.run(
                command,
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 2)
            self.assertIn("File exists", second.stderr)
            self.assertEqual(
                (output_directory / "LD_COPY.SNA").read_bytes(), snapshot_before
            )


if __name__ == "__main__":
    unittest.main()
