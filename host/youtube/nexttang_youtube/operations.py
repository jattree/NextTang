"""Mutation planning.

Every write command builds a Plan first and prints it. Applying the plan is a
separate, explicitly requested step. The planners here perform no network write
themselves, which is what makes a dry run provably harmless.
"""

from __future__ import annotations

import copy
import difflib
import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

from .errors import UsageError

ALLOWED_UPLOAD_PRIVACY = ("private",)
KNOWN_PRIVACY_VALUES = ("private", "unlisted", "public")
MAX_COMMENT_CHARACTERS = 10000
MAX_CHANNEL_DESCRIPTION_CHARACTERS = 1000


@dataclass
class Plan:
    """A described, not-yet-executed mutation."""

    operation: str
    target: str
    summary: str
    diff: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    request: dict[str, Any] = field(default_factory=dict)
    payload: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "operation": self.operation,
            "target": self.target,
            "summary": self.summary,
            "diff": self.diff,
            "notes": self.notes,
            "request": self.request,
        }


def merge_channel_description(branding: Mapping[str, Any], description: str) -> dict[str, Any]:
    """Return the full brandingSettings with only the description replaced.

    channels.update overwrites every mutable property in the part it is given,
    and a property left out of the request has its existing value deleted. The
    only safe write is therefore the complete object read back from the API
    with one field changed.
    """
    merged = copy.deepcopy(dict(branding))
    channel_block = dict(merged.get("channel") or {})
    channel_block["description"] = description
    merged["channel"] = channel_block
    return merged


def plan_channel_description(
    channel_id: str,
    branding: Mapping[str, Any],
    description: str,
) -> Plan:
    """Plan a channel description change as a read-modify-write."""
    current_channel = dict((branding or {}).get("channel") or {})
    current = current_channel.get("description", "") or ""
    if description == current:
        raise UsageError(
            "the supplied description is identical to the current channel description",
            hint="Nothing would change. Edit the file or drop the command.",
        )
    if len(description) > MAX_CHANNEL_DESCRIPTION_CHARACTERS:
        raise UsageError(
            f"channel description is {len(description)} characters, over YouTube's "
            f"{MAX_CHANNEL_DESCRIPTION_CHARACTERS} character limit"
        )

    merged = merge_channel_description(branding or {}, description)
    preserved = sorted(key for key in current_channel if key != "description")
    other_parts = sorted(key for key in (branding or {}) if key != "channel")

    notes = [
        "channels.update replaces the whole brandingSettings part, so the request "
        "carries every field read back from the API.",
        f"preserved brandingSettings.channel fields: {', '.join(preserved) if preserved else 'none'}",
        f"preserved brandingSettings sections: {', '.join(other_parts) if other_parts else 'none'}",
    ]
    if not branding:
        notes.append(
            "WARNING: the API returned empty brandingSettings, so nothing can be preserved. "
            "Resolve that before applying."
        )

    return Plan(
        operation="channel.set-description",
        target=channel_id,
        summary=(
            f"replace the channel description ({len(current)} characters) with the supplied "
            f"text ({len(description)} characters)"
        ),
        diff=list(
            difflib.unified_diff(
                current.splitlines(),
                description.splitlines(),
                fromfile="current description",
                tofile="proposed description",
                lineterm="",
            )
        ),
        notes=notes,
        request={
            "method": "PUT",
            "endpoint": "youtube/v3/channels",
            "part": "brandingSettings",
            "quota_units": 50,
        },
        payload={"channel_id": channel_id, "branding": merged},
    )


def plan_video_upload(path: Path, privacy: str, *, title: str | None = None,
                      description: str = "") -> Plan:
    """Plan a private video upload. Privacy must be stated and must be private."""
    if privacy not in KNOWN_PRIVACY_VALUES:
        raise UsageError(
            f"unknown privacy value {privacy!r}",
            hint=f"Known values: {', '.join(KNOWN_PRIVACY_VALUES)}.",
        )
    if privacy not in ALLOWED_UPLOAD_PRIVACY:
        raise UsageError(
            f"this CLI uploads only as private, not {privacy!r}",
            hint=(
                "Publishing is deliberately out of scope for this version. Upload as private "
                "and change visibility in YouTube Studio after reviewing the video."
            ),
        )
    if not path.exists():
        raise UsageError(f"video file not found: {path}")
    if not path.is_file():
        raise UsageError(f"not a regular file: {path}")

    size = path.stat().st_size
    if size == 0:
        raise UsageError(f"video file is empty: {path}")

    resolved_title = title or path.stem
    metadata = {
        "snippet": {"title": resolved_title, "description": description},
        "status": {"privacyStatus": privacy},
    }
    return Plan(
        operation="videos.upload",
        target=str(path),
        summary=f"upload {path.name} ({size} bytes) as {privacy}",
        notes=[
            "Uploads from an unverified API project created after 28 July 2020 are restricted "
            "to private viewing until the project passes Google's API compliance audit.",
            "This CLI never publishes. Change visibility in YouTube Studio after review.",
            "The made-for-kids declaration is not set by this CLI and must be made in "
            "YouTube Studio before any publishing.",
            f"sha256: {sha256_of(path)}",
        ],
        request={
            "method": "POST then PUT",
            "endpoint": "upload/youtube/v3/videos",
            "part": "snippet,status",
            "upload_type": "resumable",
            "quota_units": "1 call from the 100-per-day video upload bucket",
        },
        payload={"path": str(path), "size": size, "metadata": metadata},
    )


def plan_comment_reply(comment_id: str, text: str) -> Plan:
    """Plan a single reply to one existing comment."""
    if not comment_id.strip():
        raise UsageError("a comment ID is required")
    stripped = text.strip()
    if not stripped:
        raise UsageError("the reply text file is empty")
    if len(text) > MAX_COMMENT_CHARACTERS:
        raise UsageError(
            f"reply is {len(text)} characters, over the {MAX_COMMENT_CHARACTERS} character limit"
        )

    preview = text if len(text) <= 500 else text[:500] + "\n[... truncated in preview ...]"
    return Plan(
        operation="comments.reply",
        target=comment_id,
        summary=f"post one reply of {len(text)} characters to comment {comment_id}",
        diff=[f"+{line}" for line in preview.splitlines()],
        notes=[
            "This posts a single reply to one comment. Bulk replies are not implemented.",
            "The reply is public once posted and can only be removed through YouTube.",
        ],
        request={
            "method": "POST",
            "endpoint": "youtube/v3/comments",
            "part": "snippet",
            "quota_units": 50,
        },
        payload={"parent_id": comment_id, "text": text},
    )


def sha256_of(path: Path, chunk_size: int = 1024 * 1024) -> str:
    """Hash a file without holding it in memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()
