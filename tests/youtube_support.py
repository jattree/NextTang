"""Shared fakes for the nexttang-youtube tests.

No test in this repository is allowed to reach Google. Everything goes through
FakeTransport, which records what the CLI tried to send and answers from
scripted routes. An unmatched request is a test failure, not a live call.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

REPO_ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = REPO_ROOT / "host" / "youtube"
if str(PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_ROOT))

from nexttang_youtube.transport import Response  # noqa: E402 - path setup must run first

CHANNEL_ID = "UCzUSXeiPI3JMhlE5rmES4zA"
OTHER_CHANNEL_ID = "UCjonattreeOtherChannel00"
MUTATING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


@dataclass
class RecordedRequest:
    method: str
    url: str
    headers: dict[str, str] = field(default_factory=dict)
    body: bytes | None = None

    def json_body(self) -> Any:
        return json.loads(self.body.decode("utf-8")) if self.body else None

    @property
    def path(self) -> str:
        return self.url.split("?", 1)[0]


@dataclass
class Route:
    method: str
    contains: str
    response: Response
    remaining: int | None


class UnexpectedRequest(AssertionError):
    """Raised when the CLI tries a call the test did not script."""


class FakeTransport:
    """Injectable stand-in for UrllibTransport."""

    def __init__(self) -> None:
        self.requests: list[RecordedRequest] = []
        self._routes: list[Route] = []

    def route(
        self,
        method: str,
        contains: str,
        *,
        payload: Any = None,
        status: int = 200,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        times: int | None = None,
    ) -> "FakeTransport":
        encoded = body if body is not None else json.dumps(payload or {}).encode("utf-8")
        self._routes.append(
            Route(
                method=method.upper(),
                contains=contains,
                response=Response(status=status, headers=dict(headers or {}), body=encoded),
                remaining=times,
            )
        )
        return self

    def request(self, method, url, *, headers=None, body=None, timeout=30.0) -> Response:
        self.requests.append(
            RecordedRequest(method=method.upper(), url=url, headers=dict(headers or {}), body=body)
        )
        for route in self._routes:
            if route.method != method.upper() or route.contains not in url:
                continue
            if route.remaining is not None:
                if route.remaining <= 0:
                    continue
                route.remaining -= 1
            return route.response
        raise UnexpectedRequest(f"no route for {method.upper()} {url.split('?', 1)[0]}")

    # ------------------------------------------------------------- assertions

    @property
    def mutating_requests(self) -> list[RecordedRequest]:
        """Every request that could change remote state."""
        return [
            request
            for request in self.requests
            if request.method in MUTATING_METHODS and "oauth2.googleapis.com" not in request.url
        ]

    def calls_to(self, fragment: str) -> list[RecordedRequest]:
        return [request for request in self.requests if fragment in request.url]

    def query_values(self, fragment: str, key: str) -> list[str]:
        """Collect one query parameter across every matching request."""
        import urllib.parse

        values = []
        for request in self.calls_to(fragment):
            query = urllib.parse.urlsplit(request.url).query
            for name, value in urllib.parse.parse_qsl(query):
                if name == key:
                    values.append(value)
        return values


# ------------------------------------------------------------------ fixtures


def channel_resource(
    channel_id: str = CHANNEL_ID,
    title: str = "NextTang",
    handle: str = "@nexttangfpga",
    uploads: str = "UUzUSXeiPI3JMhlE5rmES4zA",
) -> dict[str, Any]:
    return {
        "items": [
            {
                "id": channel_id,
                "snippet": {"title": title, "customUrl": handle, "description": "Channel description"},
                "contentDetails": {"relatedPlaylists": {"uploads": uploads}},
                "statistics": {"subscriberCount": "12", "videoCount": "3", "viewCount": "456"},
            }
        ]
    }


def branding_resource(
    channel_id: str = CHANNEL_ID,
    description: str = "Original description",
    extra: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    channel_block: dict[str, Any] = {
        "title": "NextTang",
        "description": description,
        "keywords": "fpga tang zxspectrumnext",
        "country": "GB",
        "defaultLanguage": "en",
        "unsubscribedTrailer": "abcdefghijk",
    }
    if extra:
        channel_block.update(extra)
    return {
        "items": [
            {
                "id": channel_id,
                "brandingSettings": {
                    "channel": channel_block,
                    "image": {"bannerExternalUrl": "https://example.invalid/banner"},
                },
            }
        ]
    }


def comment_thread(
    thread_id: str,
    *,
    author_channel_id: str = "UCviewer0000000000000000",
    total_replies: int = 0,
    reply_authors: tuple[str, ...] = (),
    text: str = "Great work on the port",
) -> dict[str, Any]:
    thread: dict[str, Any] = {
        "id": thread_id,
        "snippet": {
            "videoId": "video123",
            "totalReplyCount": total_replies,
            "topLevelComment": {
                "id": f"{thread_id}-top",
                "snippet": {
                    "authorDisplayName": "A Viewer",
                    "authorChannelId": {"value": author_channel_id},
                    "publishedAt": "2026-08-10T12:00:00Z",
                    "updatedAt": "2026-08-10T12:00:00Z",
                    "likeCount": 1,
                    "textOriginal": text,
                },
            },
        },
    }
    if reply_authors:
        thread["replies"] = {
            "comments": [
                {
                    "id": f"{thread_id}-reply-{index}",
                    "snippet": {
                        "authorChannelId": {"value": author},
                        "textOriginal": "reply body",
                    },
                }
                for index, author in enumerate(reply_authors)
            ]
        }
    return thread


def error_payload(status: int, reason: str, message: str = "denied") -> dict[str, Any]:
    return {
        "error": {
            "code": status,
            "message": message,
            "errors": [{"reason": reason, "message": message, "domain": "youtube.quota"}],
        }
    }
