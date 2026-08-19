"""Tests for the bounded, user-supplied TZX build input."""

from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[1]
CONVERTER = REPO_ROOT / "scripts" / "tzx_to_mem.py"


def standard_block(data: bytes = b"\x00\x01") -> bytes:
    return b"\x10\xe8\x03" + len(data).to_bytes(2, "little") + data


class TzxToMemTests(unittest.TestCase):
    def run_converter(
        self, source: Path, output: Path, manifest: Path, *extra: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(CONVERTER),
                str(source),
                str(output),
                "--manifest",
                str(manifest),
                *extra,
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_converts_the_only_tzx_member_without_extracting_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            tape = b"ZXTape!\x1a\x01\x14" + standard_block()
            archive = root / "game.zip"
            with zipfile.ZipFile(archive, "w") as output_zip:
                output_zip.writestr("folder/game.tzx", tape)

            output = root / "tape.mem"
            manifest = root / "tape-input-sha256.txt"
            result = self.run_converter(archive, output, manifest)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                output.read_text(encoding="ascii"),
                "".join(f"{value:02x}\n" for value in tape + b"\x00"),
            )
            manifest_text = manifest.read_text(encoding="utf-8")
            self.assertIn("member=folder/game.tzx", manifest_text)
            self.assertIn(f"tzx_bytes={len(tape)}", manifest_text)
            self.assertFalse((root / "folder").exists())

    def test_rejects_unsupported_blocks_before_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "unsupported.tzx"
            source.write_bytes(b"ZXTape!\x1a\x01\x14\x12\x01\x00\x01\x00")
            output = root / "tape.mem"
            result = self.run_converter(source, output, root / "manifest")

            self.assertEqual(result.returncode, 1)
            self.assertIn("unsupported TZX block 0x12", result.stderr)
            self.assertFalse(output.exists())

    def test_rejects_truncated_and_oversized_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            truncated = root / "truncated.tzx"
            truncated.write_bytes(
                b"ZXTape!\x1a\x01\x14\x10\x00\x00\x04\x00\x01"
            )
            result = self.run_converter(
                truncated, root / "one.mem", root / "one.manifest"
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("truncated standard-speed block data", result.stderr)

            valid = root / "valid.tzx"
            valid.write_bytes(b"ZXTape!\x1a\x01\x14" + standard_block())
            result = self.run_converter(
                valid,
                root / "two.mem",
                root / "two.manifest",
                "--max-bytes",
                "8",
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("reserves one of its 8 bytes", result.stderr)

    def test_rejects_archives_with_an_ambiguous_tape_member(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "ambiguous.zip"
            with zipfile.ZipFile(archive, "w") as output_zip:
                output_zip.writestr("one.tzx", b"one")
                output_zip.writestr("two.tzx", b"two")

            result = self.run_converter(
                archive, root / "tape.mem", root / "manifest"
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("exactly one .tzx member", result.stderr)


if __name__ == "__main__":
    unittest.main()
