"""Mutation planning.

Every write command builds a Plan first and prints it. Applying the plan is a
separate, explicitly requested step. The planners here perform no network write
themselves, which is what makes a dry run provably harmless.
"""

from __future__ import annotations

import copy
import difflib
import hashlib
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

from .errors import UsageError

ALLOWED_UPLOAD_PRIVACY = ("private",)
KNOWN_PRIVACY_VALUES = ("private", "unlisted", "public")
MAX_COMMENT_CHARACTERS = 10000
MAX_CHANNEL_DESCRIPTION_CHARACTERS = 1000
MAX_BANNER_BYTES = 6 * 1024 * 1024
MAX_WATERMARK_BYTES = 10 * 1024 * 1024
MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024
BANNER_MINIMUM = (2048, 1152)
WATERMARK_SIZE = (150, 150)
THUMBNAIL_MINIMUM_WIDTH = 1280
MAX_VIDEO_TITLE_CHARACTERS = 100
MAX_VIDEO_DESCRIPTION_CHARACTERS = 5000
MUTABLE_VIDEO_SNIPPET_FIELDS = (
    "title",
    "description",
    "tags",
    "categoryId",
    "defaultLanguage",
    "defaultAudioLanguage",
)


@dataclass(frozen=True)
class ImageInfo:
    path: Path
    size: int
    mime_type: str
    width: int
    height: int


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


def merge_channel_banner(branding: Mapping[str, Any], banner_url: str) -> dict[str, Any]:
    """Return complete brandingSettings with only the banner URL replaced."""
    merged = copy.deepcopy(dict(branding))
    image_block = dict(merged.get("image") or {})
    image_block["bannerExternalUrl"] = banner_url
    merged["image"] = image_block
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


def plan_channel_banner(
    channel_id: str,
    branding: Mapping[str, Any],
    path: Path,
) -> Plan:
    """Plan the upload and read-modify-write needed to replace a banner."""
    image = inspect_image(path, max_bytes=MAX_BANNER_BYTES, label="banner")
    if image.width < BANNER_MINIMUM[0] or image.height < BANNER_MINIMUM[1]:
        raise UsageError(
            f"banner is {image.width}x{image.height}; YouTube requires at least 2048x1152"
        )
    if image.width * 9 != image.height * 16:
        raise UsageError(
            f"banner is {image.width}x{image.height}; YouTube channel banners must be 16:9"
        )

    current_url = str(((branding.get("image") or {}).get("bannerExternalUrl") or ""))
    return Plan(
        operation="channel.set-banner",
        target=channel_id,
        summary=f"upload {path.name} ({image.width}x{image.height}, {image.size} bytes) as the channel banner",
        diff=[
            f"-bannerExternalUrl: {current_url or '(none)'}",
            "+bannerExternalUrl: URL returned by channelBanners.insert",
        ],
        notes=[
            f"validated {image.mime_type} artwork at {image.width}x{image.height}; minimum is 2048x1152",
            f"sha256: {sha256_of(path)}",
            "This operation uses two API writes: it uploads the image, then sets the returned URL with channels.update.",
            "If the second write fails, the uploaded image may remain in Google's channel-art storage even though the visible banner is unchanged.",
            "channels.update receives the complete brandingSettings object read immediately before the write.",
        ],
        request={
            "step_1": "POST upload/youtube/v3/channelBanners/insert (channelBanners.insert)",
            "step_2": "PUT youtube/v3/channels?part=brandingSettings (channels.update)",
            "quota_units": 100,
        },
        payload={
            "channel_id": channel_id,
            "path": str(path),
            "size": image.size,
            "mime_type": image.mime_type,
            "branding": copy.deepcopy(dict(branding)),
        },
    )


def plan_channel_watermark(channel_id: str, path: Path) -> Plan:
    """Plan setting the channel-wide in-video watermark from the start."""
    image = inspect_image(path, max_bytes=MAX_WATERMARK_BYTES, label="watermark")
    if (image.width, image.height) != WATERMARK_SIZE:
        raise UsageError(
            f"watermark is {image.width}x{image.height}; this CLI requires the recommended 150x150 asset"
        )
    timing = {"type": "offsetFromStart", "offsetMs": 0}
    return Plan(
        operation="channel.set-watermark",
        target=channel_id,
        summary=f"upload {path.name} ({image.width}x{image.height}, {image.size} bytes) as the video watermark",
        notes=[
            f"validated {image.mime_type} artwork at 150x150; sha256: {sha256_of(path)}",
            "The watermark starts at the beginning; YouTube chooses the default display duration when durationMs is omitted.",
            "watermarks.set has no read-back endpoint, so success means Google accepted the request, not that every rendered video was visually inspected.",
        ],
        request={
            "method": "POST",
            "endpoint": "upload/youtube/v3/watermarks/set (watermarks.set)",
            "upload_type": "multipart",
            "quota_units": 50,
        },
        payload={
            "channel_id": channel_id,
            "path": str(path),
            "size": image.size,
            "mime_type": image.mime_type,
            "timing": timing,
        },
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


def plan_video_thumbnail(channel_id: str, video_id: str, path: Path) -> Plan:
    """Plan one custom thumbnail upload for a video on the pinned channel."""
    if not video_id.strip():
        raise UsageError("a video ID is required")
    image = inspect_image(path, max_bytes=MAX_THUMBNAIL_BYTES, label="thumbnail")
    if image.width < THUMBNAIL_MINIMUM_WIDTH:
        raise UsageError(
            f"thumbnail is {image.width}x{image.height}; this CLI requires at least "
            f"{THUMBNAIL_MINIMUM_WIDTH} pixels of width"
        )
    if image.width * 9 != image.height * 16:
        raise UsageError(
            f"thumbnail is {image.width}x{image.height}; this CLI requires a 16:9 image"
        )

    return Plan(
        operation="videos.set-thumbnail",
        target=f"video {video_id} on channel {channel_id}",
        summary=(
            f"upload {path.name} ({image.width}x{image.height}, {image.size} bytes) "
            f"as the custom thumbnail"
        ),
        notes=[
            f"validated {image.mime_type} artwork at {image.width}x{image.height}",
            f"sha256: {sha256_of(path)}",
            "The video is resolved through videos.list before both the dry run and the write; "
            "a video owned by any other channel is refused.",
            "A successful thumbnails.set response means Google accepted the image; the CLI "
            "does not change the video's visibility.",
        ],
        request={
            "method": "POST",
            "endpoint": "upload/youtube/v3/thumbnails/set (thumbnails.set)",
            "upload_type": "multipart",
            "quota_units": 50,
        },
        payload={
            "channel_id": channel_id,
            "video_id": video_id,
            "path": str(path),
            "size": image.size,
            "mime_type": image.mime_type,
        },
    )


def merge_video_metadata(
    snippet: Mapping[str, Any], title: str, description: str
) -> dict[str, Any]:
    """Keep mutable snippet fields while replacing only title and description."""
    merged = {
        key: copy.deepcopy(snippet[key])
        for key in MUTABLE_VIDEO_SNIPPET_FIELDS
        if key in snippet
    }
    merged["title"] = title
    merged["description"] = description
    return merged


def plan_video_metadata(
    channel_id: str,
    video_id: str,
    snippet: Mapping[str, Any],
    title: str,
    description: str,
) -> Plan:
    """Plan an ownership-checked title and description update."""
    if not video_id.strip():
        raise UsageError("a video ID is required")
    if not title.strip():
        raise UsageError("the title file is empty")
    if len(title) > MAX_VIDEO_TITLE_CHARACTERS:
        raise UsageError(
            f"video title is {len(title)} characters, over YouTube's "
            f"{MAX_VIDEO_TITLE_CHARACTERS} character limit"
        )
    if len(description) > MAX_VIDEO_DESCRIPTION_CHARACTERS:
        raise UsageError(
            f"video description is {len(description)} characters, over YouTube's "
            f"{MAX_VIDEO_DESCRIPTION_CHARACTERS} character limit"
        )
    if not snippet.get("categoryId"):
        raise UsageError(
            "the API returned no categoryId for the video",
            hint="videos.update requires categoryId. No metadata was changed.",
        )

    current_title = str(snippet.get("title") or "")
    current_description = str(snippet.get("description") or "")
    if title == current_title and description == current_description:
        raise UsageError(
            "the supplied title and description are identical to the current video metadata",
            hint="Nothing would change. Edit the files or drop the command.",
        )

    merged = merge_video_metadata(snippet, title, description)
    preserved = sorted(
        key
        for key in MUTABLE_VIDEO_SNIPPET_FIELDS
        if key in snippet and key not in {"title", "description"}
    )
    diff = list(
        difflib.unified_diff(
            current_title.splitlines(),
            title.splitlines(),
            fromfile="current title",
            tofile="proposed title",
            lineterm="",
        )
    )
    diff.extend(
        difflib.unified_diff(
            current_description.splitlines(),
            description.splitlines(),
            fromfile="current description",
            tofile="proposed description",
            lineterm="",
        )
    )

    return Plan(
        operation="videos.update-metadata",
        target=f"video {video_id} on channel {channel_id}",
        summary="replace the video title and description from the supplied files",
        diff=diff,
        notes=[
            "videos.update replaces the snippet fields it accepts, so the request is built "
            "from the current video resource rather than from a partial hand-written object.",
            f"preserved mutable snippet fields: {', '.join(preserved) if preserved else 'none'}",
            "The video is resolved and its ownership is checked before both the dry run and "
            "the write. Visibility and audience settings are not changed.",
        ],
        request={
            "method": "PUT",
            "endpoint": "youtube/v3/videos (videos.update)",
            "part": "snippet",
            "quota_units": 50,
        },
        payload={
            "channel_id": channel_id,
            "video_id": video_id,
            "snippet": merged,
        },
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


def inspect_image(path: Path, *, max_bytes: int, label: str) -> ImageInfo:
    """Inspect PNG/JPEG bytes and dimensions without trusting the extension."""
    if not path.exists():
        raise UsageError(f"{label} file not found: {path}")
    if not path.is_file():
        raise UsageError(f"not a regular file: {path}")
    size = path.stat().st_size
    if size == 0:
        raise UsageError(f"{label} file is empty: {path}")
    if size > max_bytes:
        raise UsageError(
            f"{label} file is {size} bytes; the limit is {max_bytes // (1024 * 1024)} MiB"
        )

    with path.open("rb") as handle:
        prefix = handle.read(24)
        if prefix.startswith(b"\x89PNG\r\n\x1a\n") and prefix[12:16] == b"IHDR":
            if len(prefix) < 24:
                raise UsageError(f"{label} is a truncated PNG: {path}")
            width, height = struct.unpack(">II", prefix[16:24])
            mime_type = "image/png"
        elif prefix.startswith(b"\xff\xd8"):
            handle.seek(2)
            width, height = _jpeg_dimensions(handle, label, path)
            mime_type = "image/jpeg"
        else:
            raise UsageError(f"{label} must contain a PNG or JPEG image: {path}")

    if width <= 0 or height <= 0:
        raise UsageError(f"{label} image has invalid dimensions {width}x{height}: {path}")
    return ImageInfo(path=path, size=size, mime_type=mime_type, width=width, height=height)


def _jpeg_dimensions(handle: Any, label: str, path: Path) -> tuple[int, int]:
    sof_markers = {
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    }
    while True:
        byte = handle.read(1)
        if not byte:
            break
        if byte != b"\xff":
            continue
        while byte == b"\xff":
            byte = handle.read(1)
        if not byte:
            break
        marker = byte[0]
        if marker in {0xD8, 0xD9, 0x01} or 0xD0 <= marker <= 0xD7:
            continue
        length_bytes = handle.read(2)
        if len(length_bytes) != 2:
            break
        length = struct.unpack(">H", length_bytes)[0]
        if length < 2:
            break
        if marker in sof_markers:
            payload = handle.read(5)
            if len(payload) != 5:
                break
            height, width = struct.unpack(">HH", payload[1:5])
            return width, height
        if marker == 0xDA:
            break
        handle.seek(length - 2, 1)
    raise UsageError(f"{label} is a truncated or unsupported JPEG: {path}")
