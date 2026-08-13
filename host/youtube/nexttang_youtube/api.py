"""YouTube Data API v3 and YouTube Analytics API v2 access.

Every list is bounded. Every mutation is a separate method that the CLI only
reaches after an explicit --apply, and channel branding is written with a
read-modify-write because channels.update overwrites the whole part it touches.

References:
  https://developers.google.com/youtube/v3/docs/channels/update
  https://developers.google.com/youtube/v3/determine_quota_cost
  https://developers.google.com/youtube/analytics/reference/reports/query
"""

from __future__ import annotations

import json
import urllib.parse
from typing import Any, Callable, Iterable, Mapping, Sequence

from .channel import ChannelIdentity
from .errors import ApiError, AuthorisationError, QuotaError, ScopeError
from .redaction import redact
from .transport import Response, Transport

DATA_API_ROOT = "https://www.googleapis.com/youtube/v3"
ANALYTICS_API_ROOT = "https://youtubeanalytics.googleapis.com/v2"
UPLOAD_API_ROOT = "https://www.googleapis.com/upload/youtube/v3"

DEFAULT_LIMIT = 25
MAX_LIMIT = 200
DATA_PAGE_SIZE = 50
COMMENT_PAGE_SIZE = 100
UPLOAD_CHUNK_BYTES = 8 * 1024 * 1024

QUOTA_REASONS = {
    "quotaExceeded",
    "dailyLimitExceeded",
    "rateLimitExceeded",
    "userRateLimitExceeded",
    "servingLimitExceeded",
}
SCOPE_REASONS = {"insufficientPermissions", "forbidden", "insufficientScope"}

ANALYTICS_SUMMARY_METRICS = (
    "views",
    "estimatedMinutesWatched",
    "averageViewDuration",
    "averageViewPercentage",
    "subscribersGained",
    "subscribersLost",
    "likes",
    "comments",
    "shares",
)


class YouTubeApi:
    """A thin, explicit client. The transport is injected so tests never fly."""

    def __init__(self, transport: Transport, access_token_provider: Callable[[], str]) -> None:
        self._transport = transport
        self._token = access_token_provider

    # ------------------------------------------------------------------ read

    def my_channel(self) -> ChannelIdentity:
        """Resolve the channel the current authorisation actually controls."""
        payload = self._get(
            f"{DATA_API_ROOT}/channels",
            {"part": "id,snippet,contentDetails,statistics", "mine": "true"},
        )
        items = payload.get("items") or []
        if not items:
            raise AuthorisationError(
                "the authorised account controls no YouTube channel",
                hint="Log in again and choose the NextTang channel identity.",
            )
        if len(items) > 1:
            raise ApiError(
                f"the authorised account returned {len(items)} channels for mine=true",
                hint="Re-run 'auth login' and select exactly the NextTang channel.",
            )
        return ChannelIdentity.from_resource(items[0])

    def channel_branding(self, channel_id: str) -> dict[str, Any]:
        """Read the current brandingSettings part for a read-modify-write."""
        payload = self._get(
            f"{DATA_API_ROOT}/channels",
            {"part": "brandingSettings", "id": channel_id},
        )
        items = payload.get("items") or []
        if not items:
            raise ApiError(f"no channel resource returned for {channel_id}")
        return items[0].get("brandingSettings") or {}

    def list_uploads(self, uploads_playlist_id: str, limit: int = DEFAULT_LIMIT) -> list[dict[str, Any]]:
        """List uploads through the uploads playlist, which costs 1 unit a page.

        search.list would cost a call from the separate 100-per-day search
        bucket and returns less reliable ordering, so it is not used here.
        """
        items = self._paged(
            f"{DATA_API_ROOT}/playlistItems",
            {"part": "snippet,contentDetails,status", "playlistId": uploads_playlist_id},
            limit=limit,
            page_size=DATA_PAGE_SIZE,
        )
        return [_flatten_playlist_item(item) for item in items]

    def video_details(self, video_ids: Sequence[str]) -> dict[str, dict[str, Any]]:
        """Fetch privacy and statistics for already-listed videos."""
        details: dict[str, dict[str, Any]] = {}
        for batch in _batched(video_ids, DATA_PAGE_SIZE):
            payload = self._get(
                f"{DATA_API_ROOT}/videos",
                {"part": "status,statistics,contentDetails", "id": ",".join(batch)},
            )
            for item in payload.get("items") or []:
                details[item["id"]] = {
                    "privacy_status": (item.get("status") or {}).get("privacyStatus"),
                    "upload_status": (item.get("status") or {}).get("uploadStatus"),
                    "duration": (item.get("contentDetails") or {}).get("duration"),
                    "view_count": (item.get("statistics") or {}).get("viewCount"),
                    "like_count": (item.get("statistics") or {}).get("likeCount"),
                    "comment_count": (item.get("statistics") or {}).get("commentCount"),
                }
        return details

    def list_playlists(self, channel_id: str, limit: int = DEFAULT_LIMIT) -> list[dict[str, Any]]:
        items = self._paged(
            f"{DATA_API_ROOT}/playlists",
            {"part": "snippet,status,contentDetails", "channelId": channel_id},
            limit=limit,
            page_size=DATA_PAGE_SIZE,
        )
        return [_flatten_playlist(item) for item in items]

    def list_comment_threads(self, channel_id: str, limit: int = DEFAULT_LIMIT) -> list[dict[str, Any]]:
        return self._paged(
            f"{DATA_API_ROOT}/commentThreads",
            {
                "part": "id,snippet,replies",
                "allThreadsRelatedToChannelId": channel_id,
                "order": "time",
                "textFormat": "plainText",
            },
            limit=limit,
            page_size=COMMENT_PAGE_SIZE,
        )

    def analytics_report(
        self,
        channel_id: str,
        start_date: str,
        end_date: str,
        metrics: Sequence[str] = ANALYTICS_SUMMARY_METRICS,
        dimensions: Sequence[str] | None = None,
    ) -> dict[str, Any]:
        parameters = {
            "ids": f"channel=={channel_id}",
            "startDate": start_date,
            "endDate": end_date,
            "metrics": ",".join(metrics),
        }
        if dimensions:
            parameters["dimensions"] = ",".join(dimensions)
        return self._get(f"{ANALYTICS_API_ROOT}/reports", parameters)

    # ----------------------------------------------------------------- write

    def update_channel_branding(self, channel_id: str, branding: Mapping[str, Any]) -> dict[str, Any]:
        """Write a complete brandingSettings part.

        The caller must pass the full object read back from the API with only
        the intended field changed. channels.update overwrites every mutable
        property in the part, and omitted properties are deleted.
        """
        body = {"id": channel_id, "brandingSettings": dict(branding)}
        return self._request(
            "PUT",
            f"{DATA_API_ROOT}/channels",
            parameters={"part": "brandingSettings"},
            json_body=body,
        )

    def insert_comment_reply(self, parent_id: str, text: str) -> dict[str, Any]:
        body = {"snippet": {"parentId": parent_id, "textOriginal": text}}
        return self._request(
            "POST",
            f"{DATA_API_ROOT}/comments",
            parameters={"part": "snippet"},
            json_body=body,
        )

    def start_resumable_upload(self, metadata: Mapping[str, Any], size: int, mime_type: str) -> str:
        """Open a resumable upload session and return its session URL."""
        parameters = {"uploadType": "resumable", "part": "snippet,status"}
        url = f"{UPLOAD_API_ROOT}/videos?{urllib.parse.urlencode(parameters)}"
        body = json.dumps(metadata).encode("utf-8")
        response = self._transport.request(
            "POST",
            url,
            headers={
                "Authorization": f"Bearer {self._token()}",
                "Content-Type": "application/json; charset=UTF-8",
                "X-Upload-Content-Length": str(size),
                "X-Upload-Content-Type": mime_type,
            },
            body=body,
        )
        if not response.ok:
            raise _map_error(response)
        location = _header(response, "location")
        if not location:
            raise ApiError("the upload session response carried no Location header")
        return location

    def upload_chunks(self, session_url: str, data: bytes, chunk_size: int = UPLOAD_CHUNK_BYTES) -> dict[str, Any]:
        """Send the file in bounded chunks, honouring 308 Resume Incomplete."""
        total = len(data)
        offset = 0
        while offset < total:
            end = min(offset + chunk_size, total) - 1
            response = self._transport.request(
                "PUT",
                session_url,
                headers={
                    "Content-Length": str(end - offset + 1),
                    "Content-Range": f"bytes {offset}-{end}/{total}",
                },
                body=data[offset : end + 1],
                timeout=600.0,
            )
            if response.status in {200, 201}:
                return response.json()
            if response.status == 308:
                offset = _resume_offset(response, fallback=end + 1)
                continue
            raise _map_error(response)
        raise ApiError("the upload finished without a completion response")

    # --------------------------------------------------------------- plumbing

    def _get(self, url: str, parameters: Mapping[str, Any]) -> dict[str, Any]:
        return self._request("GET", url, parameters=parameters)

    def _request(
        self,
        method: str,
        url: str,
        *,
        parameters: Mapping[str, Any] | None = None,
        json_body: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        target = url
        if parameters:
            target = f"{url}?{urllib.parse.urlencode(parameters)}"
        headers = {"Authorization": f"Bearer {self._token()}"}
        body = None
        if json_body is not None:
            headers["Content-Type"] = "application/json; charset=UTF-8"
            body = json.dumps(json_body).encode("utf-8")
        response = self._transport.request(method, target, headers=headers, body=body)
        if not response.ok:
            raise _map_error(response)
        payload = response.json()
        return payload if isinstance(payload, dict) else {"items": payload}

    def _paged(
        self,
        url: str,
        parameters: Mapping[str, Any],
        *,
        limit: int,
        page_size: int,
    ) -> list[dict[str, Any]]:
        """Collect at most `limit` items, never issuing an unbounded sweep."""
        bounded = validate_limit(limit)
        collected: list[dict[str, Any]] = []
        page_token: str | None = None
        # One extra page tolerates a short page from the API without looping.
        page_budget = (bounded + page_size - 1) // page_size + 1
        for _ in range(page_budget):
            remaining = bounded - len(collected)
            if remaining <= 0:
                break
            request_parameters = dict(parameters)
            request_parameters["maxResults"] = min(remaining, page_size)
            if page_token:
                request_parameters["pageToken"] = page_token
            payload = self._get(url, request_parameters)
            collected.extend(payload.get("items") or [])
            page_token = payload.get("nextPageToken")
            if not page_token:
                break
        return collected[:bounded]


def validate_limit(limit: int) -> int:
    """Bound every list command. Refuse an unbounded or absurd request."""
    if limit < 1:
        raise ApiError(f"limit must be at least 1, got {limit}")
    if limit > MAX_LIMIT:
        raise ApiError(
            f"limit {limit} exceeds the {MAX_LIMIT} record ceiling",
            hint=f"Request at most {MAX_LIMIT} records, or narrow the query.",
        )
    return limit


def _batched(values: Sequence[str], size: int) -> Iterable[Sequence[str]]:
    for start in range(0, len(values), size):
        yield values[start : start + size]


def _header(response: Response, name: str) -> str | None:
    for key, value in response.headers.items():
        if key.lower() == name.lower():
            return value
    return None


def _resume_offset(response: Response, *, fallback: int) -> int:
    """Read the next byte offset from a 308 Range header."""
    header = _header(response, "range")
    if header and "-" in header:
        try:
            return int(header.rsplit("-", 1)[1]) + 1
        except ValueError:
            return fallback
    return fallback


def _map_error(response: Response):
    """Translate an API error body into the right typed CLI failure."""
    payload: Any
    try:
        payload = response.json()
    except Exception:  # noqa: BLE001 - a malformed error body must still classify
        payload = {}
    error = payload.get("error") if isinstance(payload, dict) else {}
    if not isinstance(error, dict):
        error = {}
    message = error.get("message") or response.text()[:300] or f"HTTP {response.status}"
    details = error.get("errors") or []
    reason = details[0].get("reason") if details and isinstance(details[0], dict) else error.get("status")
    message = redact(str(message))

    if response.status == 401:
        return AuthorisationError(
            f"the API rejected the access token ({message})",
            hint="Run 'nexttang-youtube auth login' to authorise again.",
        )
    if response.status == 403 and reason in QUOTA_REASONS:
        return QuotaError(
            f"YouTube API quota or rate limit reached ({reason}: {message})",
            hint=(
                "Daily quota resets at midnight Pacific Time. Nothing was changed. "
                "Check usage on the Google Cloud Quotas page."
            ),
        )
    if response.status == 403 and reason in SCOPE_REASONS:
        return ScopeError(
            f"the authorisation lacks permission for this call ({reason}: {message})",
            hint="Grant the matching capability with 'auth login --enable <capability>'.",
        )
    if response.status == 429:
        return QuotaError(
            f"the API rate limited this client ({message})",
            hint="Retry later. Nothing was changed.",
        )
    return ApiError(
        f"the API returned HTTP {response.status} ({message})",
        status=response.status,
        reason=reason,
    )


def _flatten_playlist_item(item: Mapping[str, Any]) -> dict[str, Any]:
    snippet = item.get("snippet") or {}
    content = item.get("contentDetails") or {}
    return {
        "video_id": content.get("videoId") or (snippet.get("resourceId") or {}).get("videoId"),
        "title": snippet.get("title"),
        "published_at": content.get("videoPublishedAt") or snippet.get("publishedAt"),
        "position": snippet.get("position"),
        "privacy_status": (item.get("status") or {}).get("privacyStatus"),
        "description": snippet.get("description"),
    }


def _flatten_playlist(item: Mapping[str, Any]) -> dict[str, Any]:
    snippet = item.get("snippet") or {}
    return {
        "playlist_id": item.get("id"),
        "title": snippet.get("title"),
        "published_at": snippet.get("publishedAt"),
        "privacy_status": (item.get("status") or {}).get("privacyStatus"),
        "item_count": (item.get("contentDetails") or {}).get("itemCount"),
        "description": snippet.get("description"),
    }
