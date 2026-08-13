"""Human and JSON rendering.

Everything printed passes through the redactor, so a stray token in an error
body cannot reach a terminal, a log file, or a pasted bug report.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Callable, Mapping, Sequence

from .redaction import redact


class Printer:
    """One output object shared by every command."""

    def __init__(self, json_output: bool = False, stream=None, error_stream=None) -> None:
        self.json_output = json_output
        self._stream = stream if stream is not None else sys.stdout
        self._error_stream = error_stream if error_stream is not None else sys.stderr

    def line(self, text: str = "") -> None:
        # Flushed because the login flow prints a URL and then blocks; a
        # block-buffered pipe would hide it until the process exits.
        if not self.json_output:
            print(redact(text), file=self._stream, flush=True)

    def warn(self, text: str) -> None:
        print(redact(f"warning: {text}"), file=self._error_stream, flush=True)

    def error(self, text: str) -> None:
        print(redact(f"error: {text}"), file=self._error_stream, flush=True)

    def hint(self, text: str) -> None:
        print(redact(f"hint: {text}"), file=self._error_stream, flush=True)

    def emit(self, payload: Any, renderer: Callable[["Printer", Any], None]) -> None:
        """Render a result either as JSON or through the supplied renderer."""
        if self.json_output:
            print(
                redact(json.dumps(payload, indent=2, sort_keys=True, default=str)),
                file=self._stream,
                flush=True,
            )
        else:
            renderer(self, payload)

    def field(self, label: str, value: Any, width: int = 22) -> None:
        self.line(f"{label + ':':<{width}} {_display(value)}")

    def table(self, rows: Sequence[Mapping[str, Any]], columns: Sequence[tuple[str, str]]) -> None:
        """Print rows as an aligned table. Columns are (key, heading) pairs."""
        if not rows:
            self.line("(no records)")
            return
        widths = []
        for key, heading in columns:
            longest = max((len(_display(row.get(key))) for row in rows), default=0)
            widths.append(max(len(heading), longest))
        header = "  ".join(heading.ljust(width) for (_, heading), width in zip(columns, widths))
        self.line(header)
        self.line("  ".join("-" * width for width in widths))
        for row in rows:
            self.line(
                "  ".join(
                    _display(row.get(key)).ljust(width) for (key, _), width in zip(columns, widths)
                )
            )

    def section(self, title: str) -> None:
        self.line()
        self.line(title)
        self.line("-" * len(title))


def _display(value: Any) -> str:
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "yes" if value else "no"
    text = str(value)
    return text.replace("\n", " ").replace("\r", " ")


def truncate(text: str | None, length: int = 60) -> str:
    """Shorten free text for a table cell."""
    if not text:
        return "-"
    flattened = " ".join(text.split())
    if len(flattened) <= length:
        return flattened
    return flattened[: length - 1] + "…"
