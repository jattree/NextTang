#!/usr/bin/env python3
"""Merge a new official ZX Spectrum Next core release onto NextTang's copy.

Each row of docs/upstream-official-files.tsv names a NextTang file, the
official file it follows and that official file's Git blob as NextTang last
took it. This script three-way merges every followed file: the recorded blob
is the base, the official file at --to is theirs and the NextTang file is
ours, so NextTang's patches carry over and every official change comes in.

    scripts/merge_official_core.py --upstream ~/ZX_Spectrum_Next_FPGA --to 30205

Without --write it only reports. With --write it rewrites each merged file,
leaving conflict markers where a NextTang patch and an official change touch
the same lines, and records the new official blobs in the TSV. It exits 1 if
any file conflicts or an official file has gone, 0 otherwise.

Rows whose source is "mister-kept" or "nexttang" are not merged; the report
says whether their official counterpart changed so it can be looked at.
"""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
TSV = REPO_ROOT / "docs" / "upstream-official-files.tsv"
MERGED_SOURCES = {"official", "official-merged", "identical", "official-wedge"}


def git(upstream: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(upstream), *args], check=True,
                          capture_output=True, text=True).stdout


def blob_at(upstream: Path, rev: str, path: str) -> str | None:
    result = subprocess.run(["git", "-C", str(upstream), "rev-parse", "--verify", "-q", f"{rev}:{path}"],
                            capture_output=True, text=True)
    return result.stdout.strip() or None


def blob_text(upstream: Path, blob: str) -> bytes:
    return subprocess.run(["git", "-C", str(upstream), "cat-file", "-p", blob], check=True,
                          capture_output=True).stdout


def merge(ours: Path, base: bytes, theirs: bytes) -> tuple[bytes, int]:
    """git merge-file of ours against base and theirs; returns text and conflict count."""
    with tempfile.TemporaryDirectory() as tmp:
        base_file, theirs_file = Path(tmp, "base"), Path(tmp, "theirs")
        base_file.write_bytes(base)
        theirs_file.write_bytes(theirs)
        result = subprocess.run(["git", "merge-file", "-p", "-L", "nexttang", "-L", "base", "-L", "official",
                                 str(ours), str(base_file), str(theirs_file)], capture_output=True)
        if result.returncode < 0 or result.returncode > 127:
            raise RuntimeError(f"git merge-file failed on {ours}: {result.stderr.decode()}")
        return result.stdout, result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--upstream", type=Path, required=True, help="clone of the official FPGA repository")
    parser.add_argument("--to", required=True, help="official revision to merge (branch, tag or commit)")
    parser.add_argument("--write", action="store_true", help="rewrite the merged files and the TSV")
    args = parser.parse_args()

    to_commit = git(args.upstream, "rev-parse", "--verify", f"{args.to}^{{commit}}").strip()
    with TSV.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        fields = reader.fieldnames
        rows = list(reader)

    failures = 0
    for row in rows:
        path, official, recorded = row["path"], row["official_path"], row["official_blob"]
        new_blob = blob_at(args.upstream, to_commit, official)
        if new_blob is None:
            print(f"GONE      {path}: {official} is not in {args.to}")
            failures += 1
            continue
        if new_blob == recorded:
            print(f"same      {path}")
            continue
        if row["source"] not in MERGED_SOURCES:
            print(f"LOOK      {path}: official {official} changed, row is {row['source']}, not merged")
            continue
        text, conflicts = merge(REPO_ROOT / path, blob_text(args.upstream, recorded),
                                blob_text(args.upstream, new_blob))
        print(f"{'CONFLICT' if conflicts else 'merged':9} {path}" + (f": {conflicts} conflict(s)" if conflicts else ""))
        failures += bool(conflicts)
        if args.write:
            (REPO_ROOT / path).write_bytes(text)
            row["official_blob"] = new_blob

    if args.write:
        with TSV.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
    print(f"official {args.to} = {to_commit[:12]}; {failures} file(s) need attention")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
