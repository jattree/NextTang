#!/usr/bin/env python3
"""Run deterministic, dependency-free repository hygiene checks."""

from __future__ import annotations

import re
import stat
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATED_DIRECTORIES = {
    ".Xil",
    ".cache",
    ".tools",
    "artifacts",
    "build",
    "captures",
    "dist",
    "games",
    "gwsynthesis",
    "impl",
    "local",
    "node_modules",
    "obj_dir",
    "out",
    "pnr",
    "release",
    "roms",
    "sd-card",
    "sdcard",
    "sim_build",
    "test-media",
    "toolchains",
    "xsim.dir",
}
GENERATED_SUFFIXES = {
    ".bin",
    ".bit",
    ".dfu",
    ".dsk",
    ".elf",
    ".fs",
    ".fst",
    ".ghw",
    ".img",
    ".iso",
    ".jed",
    ".mcs",
    ".nex",
    ".rom",
    ".sal",
    ".scl",
    ".sna",
    ".sr",
    ".svf",
    ".tap",
    ".trd",
    ".tzx",
    ".ucdb",
    ".uf2",
    ".vcd",
    ".vvp",
    ".wlf",
    ".z80",
}
BINARY_SUFFIXES = GENERATED_SUFFIXES | {
    ".7z",
    ".gif",
    ".jpeg",
    ".jpg",
    ".pdf",
    ".png",
    ".sal",
    ".sr",
    ".webp",
    ".zip",
}
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HTML_LINK = re.compile(r"(?:href|src)\s*=\s*['\"]([^'\"]+)['\"]", re.IGNORECASE)
REMOTE_SCHEMES = {"data", "http", "https", "mailto"}
FORBIDDEN_SVG_ELEMENTS = {"animate", "animatemotion", "animatetransform", "foreignobject", "script", "set"}
SENSITIVE_FILENAMES = {"flexlmrc", "license.dat"}
SENSITIVE_SUFFIXES = {".lic", ".license"}
REQUIRED_IGNORED_PATHS = {
    ".env.production",
    ".tools/oss-cad-suite/bin/yosys",
    "boards/console138k/impl/pnr/project.rpt",
    "boards/console138k/src/ddr_ip/temp/DDR3/generated.vg",
    "boards/console138k/src/pll/gowin_pll_tmp.v",
    "build/vendor/console138k/release/nexttang.fs",
    "captures/session.sal",
    "host/ui/node_modules/package/index.js",
    "local/roms/owned-next.rom",
    "nexttang.lic",
    "sim/work/transcript",
    "sim/waves/core.vcd",
    "target/debug/nexttang-host",
}
REQUIRED_TRACKABLE_PATHS = {
    ".env.example",
    "boards/console138k/nexttang.gprj",
    "boards/console138k/src/constraints.cst",
    "boards/console138k/src/ddr_ip.ipc",
    "boards/console138k/src/timing.sdc",
    "rtl/core.sv",
    "rtl/core.vhd",
}


def repository_files(root: Path = REPO_ROOT) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [root / item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def path_is_ignored(relative: str, root: Path = REPO_ROOT) -> bool:
    result = subprocess.run(
        ["git", "check-ignore", "--quiet", "--no-index", "--", relative],
        cwd=root,
        check=False,
    )
    if result.returncode not in {0, 1}:
        raise RuntimeError(f"git check-ignore failed for {relative}: {result.returncode}")
    return result.returncode == 0


def gitignore_errors(root: Path = REPO_ROOT) -> list[str]:
    errors = [
        f"required local/generated path is not ignored: {path}"
        for path in sorted(REQUIRED_IGNORED_PATHS)
        if not path_is_ignored(path, root)
    ]
    errors.extend(
        f"required source/configuration path is unexpectedly ignored: {path}"
        for path in sorted(REQUIRED_TRACKABLE_PATHS)
        if path_is_ignored(path, root)
    )
    return errors


def generated_artifact_error(relative: Path) -> str | None:
    if relative.name in SENSITIVE_FILENAMES or relative.suffix.lower() in SENSITIVE_SUFFIXES:
        return f"credential or vendor license file is not allowed: {relative}"
    if relative.name == ".env" or (
        relative.name.startswith(".env.") and relative.name != ".env.example"
    ):
        return f"local environment file is not allowed: {relative}"
    if any(part in GENERATED_DIRECTORIES for part in relative.parts[:-1]):
        return f"generated output directory is not allowed: {relative}"
    if relative.suffix.lower() in GENERATED_SUFFIXES:
        return f"generated FPGA/simulation artifact is not allowed: {relative}"
    return None


def local_link_error(source: Path, destination: str, root: Path = REPO_ROOT) -> str | None:
    destination = destination.strip()
    if destination.startswith("<") and destination.endswith(">"):
        destination = destination[1:-1]
    destination = destination.split(maxsplit=1)[0]
    parsed = urllib.parse.urlsplit(destination)
    if not parsed.path or parsed.scheme.lower() in REMOTE_SCHEMES or destination.startswith("//"):
        return None

    link_path = Path(urllib.parse.unquote(parsed.path))
    resolved = (root / link_path.relative_to("/")) if link_path.is_absolute() else (source.parent / link_path)
    if not resolved.exists():
        return f"{source.relative_to(root)}: missing local link target: {destination}"
    return None


def markdown_errors(path: Path, text: str, root: Path = REPO_ROOT) -> list[str]:
    destinations = MARKDOWN_LINK.findall(text) + HTML_LINK.findall(text)
    return [error for item in destinations if (error := local_link_error(path, item, root))]


def svg_errors(path: Path, root: Path = REPO_ROOT) -> list[str]:
    relative = path.relative_to(root)
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        return [f"{relative}: invalid SVG XML: {exc}"]

    errors: list[str] = []
    for element in tree.iter():
        tag = element.tag.rsplit("}", 1)[-1].lower()
        if tag in FORBIDDEN_SVG_ELEMENTS:
            errors.append(f"{relative}: forbidden SVG element: {tag}")
        for attribute, value in element.attrib.items():
            name = attribute.rsplit("}", 1)[-1].lower()
            if name.startswith("on"):
                errors.append(f"{relative}: forbidden SVG event attribute: {name}")
            if name == "href" and urllib.parse.urlsplit(value).scheme:
                errors.append(f"{relative}: remote or embedded SVG href is not allowed: {value}")
    return errors


def text_errors(path: Path, root: Path = REPO_ROOT) -> list[str]:
    relative = path.relative_to(root)
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        return [f"{relative}: file is not UTF-8 text: {exc}"]

    errors: list[str] = []
    if text and not text.endswith("\n"):
        errors.append(f"{relative}: missing final newline")
    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.endswith((" ", "\t")):
            errors.append(f"{relative}:{line_number}: trailing whitespace")
    if path.suffix.lower() == ".md":
        errors.extend(markdown_errors(path, text, root))
    return errors


def check_repository(root: Path = REPO_ROOT) -> tuple[list[str], int]:
    errors = gitignore_errors(root)
    files = repository_files(root)
    for path in files:
        relative = path.relative_to(root)
        if error := generated_artifact_error(relative):
            errors.append(error)
        if path.suffix.lower() not in BINARY_SUFFIXES:
            errors.extend(text_errors(path, root))
        if path.suffix.lower() == ".svg":
            errors.extend(svg_errors(path, root))
        if path.suffix.lower() == ".sh" and not path.stat().st_mode & stat.S_IXUSR:
            errors.append(f"{relative}: shell script is not executable")
    return errors, len(files)


def main() -> int:
    errors, file_count = check_repository()
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"repository check: FAIL ({len(errors)} error(s))", file=sys.stderr)
        return 1
    print(f"repository check: PASS ({file_count} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
