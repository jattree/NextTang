"""The single HTTP boundary.

Every network call the CLI makes goes through a Transport, so tests replace one
object and never reach Google. Error statuses are returned as responses rather
than raised, because the API layer owns the mapping from status to CLI error.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Mapping, Protocol

from . import __version__
from .errors import ApiError
from .redaction import redact_url

USER_AGENT = f"nexttang-youtube/{__version__}"
DEFAULT_TIMEOUT = 30.0


@dataclass(frozen=True)
class Response:
    """An HTTP response with the body already read."""

    status: int
    headers: Mapping[str, str] = field(default_factory=dict)
    body: bytes = b""

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def json(self) -> Any:
        """Decode a JSON body, or an empty mapping for an empty response."""
        if not self.body:
            return {}
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ApiError(f"API returned a body that is not JSON: {exc}", status=self.status) from exc

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")


class Transport(Protocol):
    """The contract the API and OAuth layers depend on."""

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> Response:
        ...


class UrllibTransport:
    """Standard-library HTTPS transport. No third-party dependency."""

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> Response:
        if not url.startswith("https://"):
            raise ApiError(f"refusing a non-HTTPS request to {redact_url(url)}")

        merged = {"User-Agent": USER_AGENT, "Accept": "application/json"}
        merged.update(dict(headers or {}))
        request = urllib.request.Request(url, data=body, headers=merged, method=method.upper())
        try:
            with urllib.request.urlopen(request, timeout=timeout) as handle:
                return Response(
                    status=handle.status,
                    headers=dict(handle.headers.items()),
                    body=handle.read(),
                )
        except urllib.error.HTTPError as error:
            return Response(
                status=error.code,
                headers=dict(error.headers.items()) if error.headers else {},
                body=error.read(),
            )
        except urllib.error.URLError as error:
            raise ApiError(
                f"network error contacting {redact_url(url)}: {error.reason}",
                hint="Check connectivity and retry. No API state changed.",
            ) from error
