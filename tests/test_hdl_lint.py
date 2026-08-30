"""The HDL lint gate has to cover every board profile and skip cleanly.

`make test` compiles only what a testbench instantiates, so the board tops --
one file behind eighteen `ifdef` macros, selected per profile by a wrapper that
defines them and includes it -- were elaborated by nothing until a vendor build
spent minutes on them. The gate closes that. What is verified here is the
plumbing that makes it trustworthy rather than decorative:

  - every profile the build driver advertises resolves a source list, so the
    gate cannot silently cover fewer profiles than exist;
  - that list is the build's own list, not a second copy that drifts;
  - --print-sources stays side-effect free, so the gate needs no ROM images,
    snapshots, tapes or vendor tree;
  - the gate degrades to a SKIP when Verilator is absent, the way shell-lint
    already treats ShellCheck, so CI without it does not fail spuriously.

Verilator itself is not invoked here. It is not a required tool, and a unit
suite that shells out to a multi-second elaboration of twenty profiles would be
paying for coverage `make hdl-lint` already provides.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_DRIVER = REPO_ROOT / "boards" / "console138k" / "build_spectrum48.sh"
LINT_SCRIPT = REPO_ROOT / "scripts" / "hdl_lint.sh"
STUBS = REPO_ROOT / "rtl" / "lint" / "nexttang_gowin_primitive_stubs.v"
MAKEFILE = REPO_ROOT / "Makefile"


def advertised_profiles() -> list[str]:
    """The profile list exactly as scripts/hdl_lint.sh derives it."""
    usage = subprocess.run(
        ["bash", str(BUILD_DRIVER), "--help"],
        capture_output=True, text=True, check=True,
    ).stdout
    match = re.search(r"--profile ([a-z0-9|-]+)", usage)
    assert match, "the build driver's usage no longer advertises a profile list"
    return match.group(1).split("|")


def print_sources(profile: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(BUILD_DRIVER), "--profile", profile, "--print-sources"],
        capture_output=True, text=True,
    )


class PrintSourcesTest(unittest.TestCase):
    def test_every_advertised_profile_resolves(self) -> None:
        profiles = advertised_profiles()
        self.assertGreaterEqual(len(profiles), 20, profiles)
        for profile in profiles:
            with self.subTest(profile=profile):
                done = print_sources(profile)
                self.assertEqual(done.returncode, 0, done.stderr)
                lines = done.stdout.split()
                self.assertGreater(len(lines), 1, "expected a top and sources")
                top, sources = lines[0], lines[1:]
                self.assertTrue(top.startswith("nexttang_console138k"), top)
                self.assertTrue(
                    any(s.endswith((".v", ".sv")) for s in sources),
                    "a profile with no Verilog would silently lint nothing",
                )
                for source in sources:
                    self.assertTrue(
                        Path(source).is_file(),
                        f"{profile} lists a missing source: {source}",
                    )

    def test_unknown_profile_is_rejected(self) -> None:
        done = print_sources("no-such-profile")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("profile not implemented", done.stderr)

    def test_writes_nothing_and_needs_no_inputs(self) -> None:
        """The DDR and snapshot profiles need a vendor tree, a SNA and ROMs for
        a real build. Resolving a source list must need none of them, or the
        gate could not run in CI."""
        with tempfile.TemporaryDirectory() as work:
            environment = dict(os.environ)
            for variable in (
                "NEXTTANG_48K_ROM", "NEXTTANG_128K_ROM_0", "NEXTTANG_128K_ROM_1",
            ):
                environment.pop(variable, None)
            done = subprocess.run(
                ["bash", str(BUILD_DRIVER),
                 "--profile", "spec256-loader-ddr3", "--print-sources"],
                capture_output=True, text=True, cwd=work, env=environment,
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(
                sorted(Path(work).iterdir()), [],
                "--print-sources must not write anything",
            )

    def test_vendor_sources_are_excluded(self) -> None:
        """Vendor DDR3 RTL lives outside the repository and is black-boxed by
        the lint, so it must not appear in the resolved list."""
        done = print_sources("spec256-loader-ddr3")
        self.assertEqual(done.returncode, 0, done.stderr)
        for source in done.stdout.split()[1:]:
            self.assertTrue(
                source.startswith(str(REPO_ROOT)),
                f"non-repository source in the lint list: {source}",
            )

    def test_list_matches_what_the_build_compiles(self) -> None:
        """--print-sources exists so the lint list cannot drift from the build
        list. Guard the property directly: the sources named for a profile are
        the ones the driver appends to source_files for it."""
        driver = BUILD_DRIVER.read_text()
        resolved = print_sources("spec256-loader-ddr3").stdout.split()[1:]
        distinctive = [
            "rtl/memory/nexttang_spec256_main_ddr_memory.v",
            "rtl/memory/nexttang_distributed_ram.v",
            "boards/console138k/nexttang_console138k_spec256_loader_ddr3.v",
        ]
        for relative in distinctive:
            self.assertIn(relative, driver)
            self.assertIn(
                str(REPO_ROOT / relative), resolved,
                f"{relative} is in the build list but not the lint list",
            )


class LintScriptTest(unittest.TestCase):
    def test_skips_when_verilator_is_absent(self) -> None:
        """Absent Verilator must SKIP, not fail: it is an optional tool, and a
        gate that fails on a missing optional tool blocks everyone who has not
        installed it."""
        with tempfile.TemporaryDirectory() as empty_path:
            environment = dict(os.environ)
            environment["PATH"] = f"{empty_path}:/usr/bin:/bin"
            environment.pop("NEXTTANG_OSS_CAD_SUITE", None)
            done = subprocess.run(
                ["bash", str(LINT_SCRIPT)],
                capture_output=True, text=True, env=environment,
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("SKIP", done.stdout)

    def test_rejects_unknown_arguments(self) -> None:
        done = subprocess.run(
            ["bash", str(LINT_SCRIPT), "--nonsense"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(done.returncode, 0)

    def test_stub_covers_every_directly_instantiated_gowin_primitive(self) -> None:
        """The stubs stand in for the Gowin hard primitives the project
        instantiates itself. A new one added to the RTL without a stub would
        turn into a black box and quietly lose the port check."""
        stubbed = set(re.findall(r"^module ([A-Z][A-Z0-9_]*) \(", STUBS.read_text(), re.M))
        instantiated: set[str] = set()
        for path in list(REPO_ROOT.glob("rtl/**/*.v")) + \
                list(REPO_ROOT.glob("rtl/**/*.sv")) + \
                list(REPO_ROOT.glob("boards/**/*.v")) + \
                list(REPO_ROOT.glob("boards/**/*.sv")):
            if "/rtl/lint/" in path.as_posix():
                continue
            for name in re.findall(
                r"^\s{0,8}(PLL|OSER10|OSER8|IDES8|ELVDS_OBUF|TLVDS_OBUF|CLKDIV|DCS|DQCE)"
                r"\s+[A-Za-z_]",
                path.read_text(errors="replace"), re.M,
            ):
                instantiated.add(name)
        self.assertTrue(instantiated, "expected to find Gowin primitives in the RTL")
        self.assertEqual(
            instantiated - stubbed, set(),
            "add a stub in rtl/lint/nexttang_gowin_primitive_stubs.v",
        )

    def test_stub_is_not_a_build_input(self) -> None:
        """The stubs must never reach synthesis."""
        self.assertNotIn("nexttang_gowin_primitive_stubs", BUILD_DRIVER.read_text())

    def test_structural_checks_are_enabled_by_name(self) -> None:
        """These are off in Verilator's default set and are the checks worth
        having: reset-domain confusion, blocking assignment in sequential
        logic, undriven nets, latches, and case coverage. Enabling them by name
        rather than with -Wall keeps some 450 style messages out of the way; if
        someone swaps this for -Wall the signal is buried, so pin it."""
        script = LINT_SCRIPT.read_text()
        for code in (
            "SYNCASYNCNET", "BLKSEQ", "UNDRIVEN",
            "LATCH", "CASEINCOMPLETE", "CASEOVERLAP",
        ):
            self.assertIn(f"-Wwarn-{code}", script)
        # -Wall belongs to the GHDL call, never to the Verilator flags.
        verilator_flags = "".join(
            re.findall(r"verilator_flags\+?=\((.*?)\)", script, re.S)
        )
        self.assertTrue(verilator_flags)
        self.assertNotIn("-Wall", verilator_flags)

    def test_vhdl_pass_never_changes_the_verdict(self) -> None:
        """The VHDL findings are overwhelmingly in imported cores. Reporting
        them is useful; failing a profile on them would say nothing about
        whether that profile holds together, so the pass stays advisory in
        both default and --strict mode."""
        script = LINT_SCRIPT.read_text()
        self.assertIn("ghdl", script)
        self.assertIn("never changes the verdict", script)
        # The verdict is carried by `failed`; the VHDL pass must not touch it.
        vhdl_section = script.split("vhdl_warnings=0", 1)[1].split("if ((status", 1)[0]
        self.assertNotIn("failed+=", vhdl_section)

    def test_vhdl_analysis_is_memoised(self) -> None:
        """Twenty profiles share three distinct VHDL file sets. Analysing per
        profile would run GHDL twenty times for the same answer."""
        self.assertIn("analyse_vhdl", LINT_SCRIPT.read_text())
        seen = set()
        for profile in advertised_profiles():
            done = print_sources(profile)
            self.assertEqual(done.returncode, 0, done.stderr)
            vhdl = tuple(s for s in done.stdout.split() if s.endswith(".vhd"))
            self.assertTrue(vhdl, f"{profile} resolved no VHDL")
            seen.add(vhdl)
        self.assertLess(
            len(seen), 6,
            "distinct VHDL sets grew; confirm memoisation still pays off",
        )


class MakefileTest(unittest.TestCase):
    def test_hdl_lint_is_a_target_and_part_of_check(self) -> None:
        makefile = MAKEFILE.read_text()
        self.assertIn("hdl-lint:", makefile)
        self.assertIn("scripts/hdl_lint.sh", makefile)
        check = re.search(r"^check: (.+?) ##", makefile, re.M)
        assert check
        self.assertIn("hdl-lint", check.group(1).split())


if __name__ == "__main__":
    unittest.main()
