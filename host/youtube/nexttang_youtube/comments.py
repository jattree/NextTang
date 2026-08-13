"""Classify comment threads by whether the channel still owes a reply.

The API returns at most a subset of replies in the `replies` part, so a thread
whose reply list is truncated cannot be classified with certainty. That case is
reported as `uncertain` rather than guessed, and the caller decides what to do
with it. Silently calling it answered would hide a comment awaiting a reply.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping, Sequence

ANSWERED = "answered"
UNANSWERED = "unanswered"
UNCERTAIN = "uncertain"
OWN_COMMENT = "own-comment"


@dataclass(frozen=True)
class ThreadClassification:
    """One comment thread and why it landed in its bucket."""

    thread_id: str
    state: str
    reason: str
    reply_data_complete: bool
    total_reply_count: int
    observed_reply_count: int

    @property
    def needs_attention(self) -> bool:
        return self.state in {UNANSWERED, UNCERTAIN}


def _author_channel_id(comment: Mapping[str, Any]) -> str | None:
    snippet = comment.get("snippet") or {}
    author = snippet.get("authorChannelId") or {}
    if isinstance(author, Mapping):
        return author.get("value")
    return None


def classify_thread(thread: Mapping[str, Any], channel_id: str) -> ThreadClassification:
    """Decide whether the pinned channel has replied in this thread."""
    thread_id = thread.get("id", "")
    snippet = thread.get("snippet") or {}
    top_level = snippet.get("topLevelComment") or {}
    total_replies = int(snippet.get("totalReplyCount", 0) or 0)
    replies = ((thread.get("replies") or {}).get("comments")) or []
    observed = len(replies)

    if _author_channel_id(top_level) == channel_id:
        return ThreadClassification(
            thread_id=thread_id,
            state=OWN_COMMENT,
            reason="the top-level comment was posted by the channel itself",
            reply_data_complete=observed >= total_replies,
            total_reply_count=total_replies,
            observed_reply_count=observed,
        )

    if any(_author_channel_id(reply) == channel_id for reply in replies):
        return ThreadClassification(
            thread_id=thread_id,
            state=ANSWERED,
            reason="a reply in this thread was posted by the channel",
            reply_data_complete=observed >= total_replies,
            total_reply_count=total_replies,
            observed_reply_count=observed,
        )

    if total_replies == 0:
        return ThreadClassification(
            thread_id=thread_id,
            state=UNANSWERED,
            reason="the thread has no replies",
            reply_data_complete=True,
            total_reply_count=0,
            observed_reply_count=0,
        )

    if observed >= total_replies:
        return ThreadClassification(
            thread_id=thread_id,
            state=UNANSWERED,
            reason=f"all {total_replies} replies were inspected and none came from the channel",
            reply_data_complete=True,
            total_reply_count=total_replies,
            observed_reply_count=observed,
        )

    return ThreadClassification(
        thread_id=thread_id,
        state=UNCERTAIN,
        reason=(
            f"only {observed} of {total_replies} replies were returned, so a channel reply "
            "cannot be ruled out"
        ),
        reply_data_complete=False,
        total_reply_count=total_replies,
        observed_reply_count=observed,
    )


def summarise_thread(thread: Mapping[str, Any], classification: ThreadClassification) -> dict[str, Any]:
    """Flatten a thread into the record both output modes render."""
    snippet = thread.get("snippet") or {}
    top_level = snippet.get("topLevelComment") or {}
    comment_snippet = top_level.get("snippet") or {}
    return {
        "thread_id": classification.thread_id,
        "comment_id": top_level.get("id"),
        "state": classification.state,
        "reason": classification.reason,
        "reply_data_complete": classification.reply_data_complete,
        "total_reply_count": classification.total_reply_count,
        "observed_reply_count": classification.observed_reply_count,
        "author": comment_snippet.get("authorDisplayName"),
        "published_at": comment_snippet.get("publishedAt"),
        "updated_at": comment_snippet.get("updatedAt"),
        "video_id": snippet.get("videoId"),
        "like_count": comment_snippet.get("likeCount"),
        "text": comment_snippet.get("textOriginal") or comment_snippet.get("textDisplay"),
    }


def select_unanswered(
    threads: Sequence[Mapping[str, Any]],
    channel_id: str,
    *,
    include_uncertain: bool = True,
) -> list[dict[str, Any]]:
    """Return the threads that plausibly still need a reply."""
    selected: list[dict[str, Any]] = []
    for thread in threads:
        classification = classify_thread(thread, channel_id)
        if classification.state == UNANSWERED or (include_uncertain and classification.state == UNCERTAIN):
            selected.append(summarise_thread(thread, classification))
    return selected
