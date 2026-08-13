"""The pinned channel identity and the guard every authenticated call passes.

The channel ID is immutable and is the only value trusted for the identity
decision. Title and handle are mutable, so a difference there is reported as a
warning and never as authorisation to act on a different channel.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

from .errors import ChannelMismatchError

CHANNEL_ID = "UCzUSXeiPI3JMhlE5rmES4zA"
CHANNEL_HANDLE = "@NextTangFPGA"
CHANNEL_TITLE = "NextTang"
CHANNEL_URL = "https://www.youtube.com/@NextTangFPGA"


@dataclass(frozen=True)
class ChannelIdentity:
    """What the API says the authorised credential currently controls."""

    channel_id: str
    title: str | None = None
    handle: str | None = None
    uploads_playlist_id: str | None = None
    subscriber_count: str | None = None
    video_count: str | None = None
    view_count: str | None = None
    description: str | None = None

    @classmethod
    def from_resource(cls, resource: Mapping[str, Any]) -> "ChannelIdentity":
        snippet = resource.get("snippet") or {}
        statistics = resource.get("statistics") or {}
        related = (resource.get("contentDetails") or {}).get("relatedPlaylists") or {}
        return cls(
            channel_id=resource.get("id", ""),
            title=snippet.get("title"),
            handle=snippet.get("customUrl"),
            uploads_playlist_id=related.get("uploads"),
            subscriber_count=statistics.get("subscriberCount"),
            video_count=statistics.get("videoCount"),
            view_count=statistics.get("viewCount"),
            description=snippet.get("description"),
        )

    def as_dict(self) -> dict[str, Any]:
        return {
            "channel_id": self.channel_id,
            "title": self.title,
            "handle": self.handle,
            "uploads_playlist_id": self.uploads_playlist_id,
            "subscriber_count": self.subscriber_count,
            "video_count": self.video_count,
            "view_count": self.view_count,
        }


def normalise_handle(handle: str | None) -> str | None:
    """Compare handles without case or leading-@ noise."""
    if not handle:
        return None
    return handle.strip().lstrip("@").lower() or None


def verify(identity: ChannelIdentity, *, expected_id: str = CHANNEL_ID) -> list[str]:
    """Refuse a different channel; return warnings for mutable-field drift.

    Raises ChannelMismatchError when the immutable ID does not match. A changed
    title or handle is reported to the caller but does not block the operation,
    because both can legitimately change on the pinned channel.
    """
    if not identity.channel_id:
        raise ChannelMismatchError(expected_id, "unknown", observed_title=identity.title)
    if identity.channel_id != expected_id:
        raise ChannelMismatchError(expected_id, identity.channel_id, observed_title=identity.title)

    warnings: list[str] = []
    if identity.title and identity.title != CHANNEL_TITLE:
        warnings.append(
            f"channel title is {identity.title!r}, expected {CHANNEL_TITLE!r}; "
            "the pinned channel ID still matches"
        )
    observed_handle = normalise_handle(identity.handle)
    expected_handle = normalise_handle(CHANNEL_HANDLE)
    if observed_handle and observed_handle != expected_handle:
        warnings.append(
            f"channel handle is @{observed_handle}, expected {CHANNEL_HANDLE}; "
            "the pinned channel ID still matches"
        )
    return warnings
