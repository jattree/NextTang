#!/usr/bin/env python3
"""Compare two traces written by tb_zxnext_trace.vhd, cycle by cycle.

Each trace logs the outputs only when they change, so both are replayed side by
side and compared at every 28 MHz cycle. Reports the first cycle on which they
differ, with the fields that differ there, and how many cycles each field
differs on in total. Exit status 0 means identical over the shorter trace.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import trace_fields  # noqa: E402


def changes(path: Path):
    with path.open() as trace:
        for line in trace:
            cycle, word = line.split()
            yield int(cycle), word


def compare(left: Path, right: Path, limit: int | None = None):
    """(first difference or None, per-field differing-cycle counts, cycles compared)."""
    left_changes = changes(left)
    right_changes = changes(right)
    next_left = next(left_changes, None)
    next_right = next(right_changes, None)
    left_word = right_word = None
    counts: Counter[str] = Counter()
    first = None
    cycle = 0
    end = None
    while True:
        while next_left is not None and next_left[0] <= cycle:
            left_word = next_left[1]
            next_left = next(left_changes, None)
        while next_right is not None and next_right[0] <= cycle:
            right_word = next_right[1]
            next_right = next(right_changes, None)
        if next_left is None and next_right is None:
            end = cycle
            break
        if limit is not None and cycle >= limit:
            end = cycle
            break
        if left_word != right_word:
            a = trace_fields.decode(left_word)
            b = trace_fields.decode(right_word)
            fields = [name for name in a if a[name] != b[name]]
            counts.update(fields)
            if first is None:
                first = (cycle, fields, a, b)
        # Jump to the next change in either trace; nothing differs in between
        # that was not already counted on this cycle, so count the span.
        upcoming = [c for c in (next_left, next_right) if c is not None]
        step_to = min(c[0] for c in upcoming)
        if left_word != right_word and step_to > cycle + 1:
            a = trace_fields.decode(left_word)
            b = trace_fields.decode(right_word)
            for name in a:
                if a[name] != b[name]:
                    counts[name] += step_to - cycle - 1
        cycle = step_to
    return first, counts, end


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path)
    parser.add_argument("--limit", type=int, help="compare only the first N cycles")
    args = parser.parse_args()
    first, counts, end = compare(args.left, args.right, args.limit)
    if first is None:
        print(f"identical over {end} cycles")
        return 0
    cycle, fields, a, b = first
    print(f"first difference at cycle {cycle}: {', '.join(fields)}")
    for name in fields:
        print(f"  {name}: {a[name]} vs {b[name]}")
    print("cycles differing, by field:")
    for name, count in counts.most_common():
        print(f"  {name:<12} {count}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
