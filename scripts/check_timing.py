#!/usr/bin/env python3
"""Decide whether a Gowin timing report passes, from the fields that mean it.

The check this replaces in build_cpu.sh searched the whole report for any
negative number. Clock skew is reported per path and is routinely negative, so
clean builds were reported as violating and an image that met timing was
rejected fifty times over. The verdict is the violated-endpoint count the tool
publishes in its run summary, which is what the sibling build scripts already
read.

Gowin writes that summary into both the HTML report and, with
`set_option -gen_text_timing_rpt 1`, a plain text one. Both are accepted: the
field name is followed by its value in either, once HTML tags are out of the
way. Worst slack is reported alongside as a margin figure, not as the verdict.
"""

import argparse
import html
import re
import sys
from pathlib import Path

ANALYSES = ("Setup", "Hold")

# Both report forms echo the command that produced each section. That line is
# the anchor for the worst-slack figure: the section headings alone also appear
# in the text report's table of contents, where scanning forward lands in
# whichever section happens to come first in the file.
SLACK_ANCHOR = "report_timing -{}"
SLACK_VALUE = re.compile(r"(?<![\w.-])(-?\d+\.\d{3})(?![\d.])")


def load(report: Path) -> tuple[str, str]:
    """Report text with HTML markup removed, and which form it was."""
    raw = report.read_text(errors="replace")
    if report.suffix.lower() in (".html", ".htm"):
        # Tag stripping would eat the <Field>:value markers of the text form,
        # so it is applied only where there is markup to strip.
        return html.unescape(re.sub(r"<[^>]+>", "\n", raw)), "html"
    return raw, "text"


def violated_endpoints(text: str, analysis: str) -> int | None:
    """The count the tool itself publishes in its run summary."""
    field = f"Numbers of {analysis} Violated Endpoints"
    match = re.search(re.escape(field) + r"[^\d-]*(\d+)", text)
    return int(match.group(1)) if match else None


def worst_slack(text: str, analysis: str) -> float | None:
    """Slack of the worst path in the analysis section, for margin reporting."""
    anchor = SLACK_ANCHOR.format(analysis.lower())
    position = text.find(anchor)
    if position == -1:
        return None
    match = SLACK_VALUE.search(text, position + len(anchor))
    return float(match.group(1)) if match else None


def check(report: Path) -> tuple[bool, list[str]]:
    text, _ = load(report)
    passed = True
    messages = []

    for analysis in ANALYSES:
        name = analysis.lower()
        violated = violated_endpoints(text, analysis)
        slack = worst_slack(text, analysis)
        margin = f", worst slack {slack:.3f} ns" if slack is not None else ""

        if violated is None:
            messages.append(f"{name}: no violated-endpoint count in the report")
            passed = False
        elif violated:
            messages.append(f"{name}: FAIL, {violated} endpoints violated{margin}")
            passed = False
        else:
            messages.append(f"{name}: pass, 0 endpoints violated{margin}")

    return passed, messages


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    arguments = parser.parse_args()

    if not arguments.report.is_file():
        # Fail closed. A build that produced no timing report has not been shown
        # to meet timing, and passing here is the same fail-open shape as the
        # check this replaced.
        print(f"timing check: FAIL, no report at {arguments.report}")
        return 1

    passed, messages = check(arguments.report)
    for message in messages:
        print(f"timing check: {message}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
