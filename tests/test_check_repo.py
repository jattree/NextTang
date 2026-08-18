from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_repo.py"
SPEC = importlib.util.spec_from_file_location("check_repo", SCRIPT)
assert SPEC and SPEC.loader
check_repo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_repo)


class CheckRepoTests(unittest.TestCase):
    def test_repository_files_excludes_untracked_nested_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            nested = root / "nested-project"
            nested.mkdir()
            subprocess.run(["git", "init", "--quiet"], cwd=nested, check=True)
            (nested / "README.md").write_text("# Nested\n", encoding="utf-8")

            files = check_repo.repository_files(root)

            self.assertNotIn(nested, files)
            self.assertTrue(all(path.is_file() for path in files))

    def test_generated_artifacts_are_rejected(self) -> None:
        self.assertIsNotNone(check_repo.generated_artifact_error(Path("build/core.fs")))
        self.assertIsNotNone(check_repo.generated_artifact_error(Path("release.bit")))
        self.assertIsNotNone(check_repo.generated_artifact_error(Path(".env.production")))
        self.assertIsNotNone(check_repo.generated_artifact_error(Path("gowin.lic")))
        self.assertIsNone(check_repo.generated_artifact_error(Path(".env.example")))
        self.assertIsNone(check_repo.generated_artifact_error(Path("rtl/core.sv")))

    def test_oauth_credentials_are_rejected(self) -> None:
        rejected = [
            "client_secret_123-abc.apps.googleusercontent.com.json",
            "host/youtube/token.json",
            "credentials.json",
            "nexttang.oauth.json",
        ]
        for path in rejected:
            self.assertIsNotNone(
                check_repo.generated_artifact_error(Path(path)), f"{path} must be rejected"
            )
        self.assertIsNone(check_repo.generated_artifact_error(Path("host/youtube/nexttang_youtube/oauth.py")))

    def test_local_markdown_links_are_resolved_from_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = root / "docs"
            docs.mkdir()
            source = docs / "guide.md"
            source.write_text("[roadmap](../ROADMAP.md)\n", encoding="utf-8")
            (root / "ROADMAP.md").write_text("# Roadmap\n", encoding="utf-8")
            self.assertEqual(check_repo.markdown_errors(source, source.read_text(), root), [])

            source.write_text("[missing](missing.md)\n", encoding="utf-8")
            self.assertEqual(len(check_repo.markdown_errors(source, source.read_text(), root)), 1)

    def test_active_svg_content_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            svg = root / "unsafe.svg"
            svg.write_text('<svg xmlns="http://www.w3.org/2000/svg"><script /></svg>\n', encoding="utf-8")
            self.assertTrue(check_repo.svg_errors(svg, root))

    def test_gitignore_policy_protects_outputs_and_keeps_sources(self) -> None:
        self.assertEqual(check_repo.gitignore_errors(), [])

    def test_gitignore_policy_detects_missing_rule(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            (root / ".gitignore").write_text("/build/\n", encoding="utf-8")

            original_ignored = check_repo.REQUIRED_IGNORED_PATHS
            original_trackable = check_repo.REQUIRED_TRACKABLE_PATHS
            try:
                check_repo.REQUIRED_IGNORED_PATHS = {"build/core.fs", "secret.lic"}
                check_repo.REQUIRED_TRACKABLE_PATHS = {"rtl/core.sv"}
                errors = check_repo.gitignore_errors(root)
            finally:
                check_repo.REQUIRED_IGNORED_PATHS = original_ignored
                check_repo.REQUIRED_TRACKABLE_PATHS = original_trackable

            self.assertEqual(errors, ["required local/generated path is not ignored: secret.lic"])

    def test_audited_imports_are_exempt_from_formatting_rules(self) -> None:
        # Vendored upstream source is verified byte-for-byte against Git blob
        # hashes, so reformatting it would break the provenance claim. The
        # exemption must apply to a path the manifest marks as imported.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            (root / "docs" / "upstream-files.tsv").write_text(
                "path\tgit_blob\tobserved_notice\tdisposition\n"
                "rtl/cpu/vendor.vhd\tabc123\tBSD-3-Clause\timported-notice-retained\n",
                encoding="utf-8")
            (root / "rtl" / "cpu").mkdir(parents=True)
            vendored = root / "rtl" / "cpu" / "vendor.vhd"
            vendored.write_text("-- trailing space here   \nno final newline", encoding="utf-8")

            self.assertEqual(check_repo.text_errors(vendored, root), [])

    def test_the_exemption_does_not_cover_project_files(self) -> None:
        # The hole must be exactly the manifest's imported paths and no wider,
        # or the formatting rules quietly stop applying to our own code.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "docs").mkdir()
            (root / "docs" / "upstream-files.tsv").write_text(
                "path\tgit_blob\tobserved_notice\tdisposition\n"
                "rtl/cpu/vendor.vhd\tabc123\tBSD-3-Clause\timported-notice-retained\n"
                "rtl/cpu/candidate.vhd\tdef456\tBSD-3-Clause\tcandidate-import-retain-notice\n",
                encoding="utf-8")
            (root / "rtl" / "cpu").mkdir(parents=True)

            ours = root / "rtl" / "ours.v"
            ours.write_text("// trailing space   \n", encoding="utf-8")
            self.assertTrue(check_repo.text_errors(ours, root),
                            "project files must still be checked")

            # A path still listed as a candidate has not been imported, so it
            # gets no exemption either.
            candidate = root / "rtl" / "cpu" / "candidate.vhd"
            candidate.write_text("-- trailing space   \n", encoding="utf-8")
            self.assertTrue(check_repo.text_errors(candidate, root),
                            "un-imported candidates must still be checked")


if __name__ == "__main__":
    unittest.main()
