"""Command line surface for the NextTang YouTube CLI.

Read commands are safe to run at any time. Write commands describe themselves
and stop; they mutate only when --apply is given, and they re-verify the pinned
channel immediately before the mutating call.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
import webbrowser
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

from . import __version__, channel as channel_module, comments as comments_module, oauth, operations, storage
from .api import DEFAULT_LIMIT, MAX_LIMIT, YouTubeApi, validate_limit
from .channel import CHANNEL_HANDLE, CHANNEL_ID, CHANNEL_TITLE, CHANNEL_URL, ChannelIdentity
from .errors import (
    EXIT_AUTH_REQUIRED,
    EXIT_NO_CREDENTIALS,
    EXIT_OK,
    CliError,
    UsageError,
)
from .oauth import AuthSession, ClientCredentials
from .output import Printer, truncate
from .transport import Transport, UrllibTransport

PROGRAM = "nexttang-youtube"
UPLOAD_MIME_TYPE = "video/*"


@dataclass
class Context:
    """Per-invocation wiring. The transport is the only injection point tests need."""

    args: argparse.Namespace
    printer: Printer
    transport: Transport
    _session: AuthSession | None = None
    _api: YouTubeApi | None = None
    _identity: ChannelIdentity | None = None

    @property
    def session(self) -> AuthSession:
        if self._session is None:
            self._session = AuthSession(self.transport)
        return self._session

    @property
    def api(self) -> YouTubeApi:
        if self._api is None:
            self._api = YouTubeApi(self.transport, self.session.access_token)
        return self._api

    def guarded_channel(self, *, force: bool = False) -> ChannelIdentity:
        """Resolve the authorised channel and refuse anything that is not NextTang.

        Costs one quota unit per resolution. Mutating commands pass force=True to
        re-resolve immediately before the write rather than trusting the earlier
        check in the same run.
        """
        if self._identity is not None and not force:
            return self._identity
        identity = self.api.my_channel()
        for warning in channel_module.verify(identity):
            self.printer.warn(warning)
        self._identity = identity
        return identity


# --------------------------------------------------------------------- status


def command_status(context: Context) -> int:
    printer = context.printer
    config_directory = storage.config_dir()
    client_path = storage.client_secret_path()
    token_path = storage.token_path()

    payload: dict[str, Any] = {
        "version": __version__,
        "pinned_channel": {
            "channel_id": CHANNEL_ID,
            "handle": CHANNEL_HANDLE,
            "title": CHANNEL_TITLE,
            "url": CHANNEL_URL,
        },
        "config_directory": str(config_directory),
        "config_directory_mode": storage.describe_permissions(config_directory),
        "client_secret_present": client_path.exists(),
        "client_secret_mode": storage.describe_permissions(client_path),
        "token_present": token_path.exists(),
        "token_mode": storage.describe_permissions(token_path),
    }

    state = context.session.stored_state() if token_path.exists() else None
    payload["authorisation"] = oauth.dump_state_for_display(state)
    payload["granted_scopes"] = list(state.scopes) if state else []
    payload["capabilities_granted"] = list(state.capabilities) if state else []
    payload["write_capabilities_granted"] = sorted(
        name for name in payload["capabilities_granted"] if name in oauth.WRITE_CAPABILITIES
    )

    exit_code = EXIT_OK
    if not client_path.exists():
        payload["ready"] = False
        payload["blocker"] = "no OAuth client credential installed"
        exit_code = EXIT_NO_CREDENTIALS
    elif state is None:
        payload["ready"] = False
        payload["blocker"] = "no stored authorisation; run 'auth login'"
        exit_code = EXIT_AUTH_REQUIRED
    elif context.args.offline:
        payload["ready"] = True
        payload["channel_check"] = "skipped (--offline)"
    else:
        identity = context.guarded_channel()
        payload["ready"] = True
        payload["channel_check"] = "verified against the pinned channel ID"
        payload["channel"] = identity.as_dict()

    printer.emit(payload, _render_status)
    return exit_code


def _render_status(printer: Printer, payload: dict[str, Any]) -> None:
    printer.line(f"{PROGRAM} {payload['version']}")
    printer.section("Pinned channel")
    pinned = payload["pinned_channel"]
    printer.field("channel ID", pinned["channel_id"])
    printer.field("handle", pinned["handle"])
    printer.field("title", pinned["title"])

    printer.section("Local credential store")
    printer.field("directory", payload["config_directory"])
    printer.field("directory mode", payload["config_directory_mode"])
    printer.field("client secret", _describe_file(payload["client_secret_mode"]))
    printer.field("token state", _describe_file(payload["token_mode"]))

    printer.section("Authorisation")
    authorisation = payload["authorisation"]
    if not authorisation.get("authorised"):
        printer.field("authorised", "no")
    else:
        printer.field("authorised", "yes")
        printer.field("access token expires", authorisation.get("access_token_expires_at"))
        for scope in payload["granted_scopes"]:
            printer.line(f"  scope: {scope}")
        granted = payload["capabilities_granted"]
        printer.field("capabilities", ", ".join(granted) if granted else "none (read-only)")
        writes = payload["write_capabilities_granted"]
        printer.field("write capabilities", ", ".join(writes) if writes else "none (read-only)")

    printer.section("Result")
    if payload.get("ready") and "channel" in payload:
        identity = payload["channel"]
        printer.field("resolved channel", identity["channel_id"])
        printer.field("title", identity["title"])
        printer.field("handle", identity["handle"])
        printer.line("channel identity verified against the pinned channel ID")
    elif payload.get("ready"):
        printer.line(str(payload.get("channel_check")))
    else:
        printer.line(f"not ready: {payload.get('blocker')}")


# -------------------------------------------------------------------- channel


def command_channel_show(context: Context) -> int:
    identity = context.guarded_channel()
    branding = context.api.channel_branding(identity.channel_id)
    channel_block = branding.get("channel") or {}
    payload = {
        "channel": identity.as_dict(),
        "url": CHANNEL_URL,
        "description": channel_block.get("description"),
        "keywords": channel_block.get("keywords"),
        "country": channel_block.get("country"),
        "default_language": channel_block.get("defaultLanguage"),
        "unsubscribed_trailer": channel_block.get("unsubscribedTrailer"),
    }
    context.printer.emit(payload, _render_channel_show)
    return EXIT_OK


def _render_channel_show(printer: Printer, payload: dict[str, Any]) -> None:
    identity = payload["channel"]
    printer.field("channel ID", identity["channel_id"])
    printer.field("title", identity["title"])
    printer.field("handle", identity["handle"])
    printer.field("url", payload["url"])
    printer.field("subscribers", identity["subscriber_count"])
    printer.field("videos", identity["video_count"])
    printer.field("views", identity["view_count"])
    printer.field("country", payload["country"])
    printer.field("default language", payload["default_language"])
    printer.field("keywords", payload["keywords"])
    printer.section("Description")
    printer.line(payload["description"] or "(empty)")


def command_channel_set_description(context: Context) -> int:
    text = _read_text_file(Path(context.args.file), "description")
    identity = context.guarded_channel()
    branding = context.api.channel_branding(identity.channel_id)
    plan = operations.plan_channel_description(identity.channel_id, branding, text)

    if not context.args.apply:
        _emit_plan(context, plan, applied=False)
        return EXIT_OK

    context.session.require_scope(oauth.SCOPE_YOUTUBE_MANAGE, capability="channel-write")
    verified = context.guarded_channel(force=True)
    fresh_branding = context.api.channel_branding(verified.channel_id)
    if (fresh_branding.get("channel") or {}) != (branding.get("channel") or {}):
        raise UsageError(
            "the channel branding changed between the plan and the apply step",
            hint="Re-run the dry run, confirm the new diff, then apply again.",
        )
    merged = operations.merge_channel_description(fresh_branding, text)
    context.api.update_channel_branding(verified.channel_id, merged)
    _emit_plan(context, plan, applied=True, extra={"channel_id": verified.channel_id})
    return EXIT_OK


def command_channel_set_banner(context: Context) -> int:
    path = Path(context.args.file)
    identity = context.guarded_channel()
    branding = context.api.channel_branding(identity.channel_id)
    plan = operations.plan_channel_banner(identity.channel_id, branding, path)

    if not context.args.apply:
        _emit_plan(context, plan, applied=False)
        return EXIT_OK

    context.session.require_scope(oauth.SCOPE_YOUTUBE_FORCE_SSL, capability="banner-write")
    verified = context.guarded_channel(force=True)
    fresh_branding = context.api.channel_branding(verified.channel_id)
    if fresh_branding != branding:
        raise UsageError(
            "the channel branding changed between the plan and the apply step",
            hint="Re-run the dry run, confirm the new diff, then apply again.",
        )

    banner_url = context.api.upload_channel_banner(path, plan.payload["mime_type"])
    merged = operations.merge_channel_banner(fresh_branding, banner_url)
    try:
        context.api.update_channel_branding(verified.channel_id, merged)
    except CliError as error:
        partial = (
            "The banner image upload completed before this failure. The visible channel banner "
            "may or may not have changed; inspect 'channel show' and YouTube Studio before retrying."
        )
        error.hint = f"{error.hint} {partial}" if error.hint else partial
        raise

    _emit_plan(
        context,
        plan,
        applied=True,
        extra={
            "channel_id": verified.channel_id,
            "banner_url": banner_url,
            "verification": "both API writes accepted; visual verification still required",
        },
    )
    return EXIT_OK


def command_channel_set_watermark(context: Context) -> int:
    path = Path(context.args.file)
    identity = context.guarded_channel()
    plan = operations.plan_channel_watermark(identity.channel_id, path)

    if not context.args.apply:
        _emit_plan(context, plan, applied=False)
        return EXIT_OK

    context.session.require_scope(oauth.SCOPE_YOUTUBE_FORCE_SSL, capability="watermark-write")
    verified = context.guarded_channel(force=True)
    context.api.set_channel_watermark(
        verified.channel_id,
        path,
        plan.payload["mime_type"],
        plan.payload["timing"],
    )
    _emit_plan(
        context,
        plan,
        applied=True,
        extra={
            "channel_id": verified.channel_id,
            "verification": "watermarks.set accepted; there is no API read-back endpoint",
        },
    )
    return EXIT_OK


# --------------------------------------------------------------------- videos


def command_videos_list(context: Context) -> int:
    limit = validate_limit(context.args.limit)
    identity = context.guarded_channel()
    if not identity.uploads_playlist_id:
        raise UsageError("the channel resource carried no uploads playlist")

    videos = context.api.list_uploads(identity.uploads_playlist_id, limit=limit)
    if context.args.details and videos:
        details = context.api.video_details([video["video_id"] for video in videos if video["video_id"]])
        for video in videos:
            video.update(details.get(video["video_id"], {}))

    payload = {
        "channel_id": identity.channel_id,
        "limit": limit,
        "returned": len(videos),
        "videos": videos,
    }
    context.printer.emit(payload, _render_videos)
    return EXIT_OK


def _render_videos(printer: Printer, payload: dict[str, Any]) -> None:
    printer.line(f"channel {payload['channel_id']}: {payload['returned']} of at most {payload['limit']} records")
    printer.line()
    rows = [
        {
            "video_id": video.get("video_id"),
            "published_at": (video.get("published_at") or "-")[:10],
            "privacy": video.get("privacy_status"),
            "views": video.get("view_count"),
            "title": truncate(video.get("title"), 52),
        }
        for video in payload["videos"]
    ]
    printer.table(
        rows,
        [
            ("video_id", "VIDEO ID"),
            ("published_at", "PUBLISHED"),
            ("privacy", "PRIVACY"),
            ("views", "VIEWS"),
            ("title", "TITLE"),
        ],
    )


def command_videos_upload(context: Context) -> int:
    path = Path(context.args.path)
    plan = operations.plan_video_upload(
        path,
        context.args.privacy,
        title=context.args.title,
        description=_optional_text(context.args.description_file),
    )
    identity = context.guarded_channel()
    plan.target = f"{path} -> channel {identity.channel_id}"

    if not context.args.apply:
        _emit_plan(context, plan, applied=False)
        return EXIT_OK

    context.session.require_scope(oauth.SCOPE_YOUTUBE_UPLOAD, capability="upload")
    verified = context.guarded_channel(force=True)
    session_url = context.api.start_resumable_upload(
        plan.payload["metadata"], plan.payload["size"], UPLOAD_MIME_TYPE
    )
    result = context.api.upload_file(session_url, path, UPLOAD_MIME_TYPE)
    _emit_plan(
        context,
        plan,
        applied=True,
        extra={
            "channel_id": verified.channel_id,
            "video_id": result.get("id"),
            "privacy_status": (result.get("status") or {}).get("privacyStatus"),
        },
    )
    return EXIT_OK


# ------------------------------------------------------------------ playlists


def command_playlists_list(context: Context) -> int:
    limit = validate_limit(context.args.limit)
    identity = context.guarded_channel()
    playlists = context.api.list_playlists(identity.channel_id, limit=limit)
    payload = {
        "channel_id": identity.channel_id,
        "limit": limit,
        "returned": len(playlists),
        "playlists": playlists,
    }
    context.printer.emit(payload, _render_playlists)
    return EXIT_OK


def _render_playlists(printer: Printer, payload: dict[str, Any]) -> None:
    printer.line(f"channel {payload['channel_id']}: {payload['returned']} of at most {payload['limit']} records")
    printer.line()
    rows = [
        {
            "playlist_id": item.get("playlist_id"),
            "items": item.get("item_count"),
            "privacy": item.get("privacy_status"),
            "title": truncate(item.get("title"), 52),
        }
        for item in payload["playlists"]
    ]
    printer.table(
        rows,
        [
            ("playlist_id", "PLAYLIST ID"),
            ("items", "ITEMS"),
            ("privacy", "PRIVACY"),
            ("title", "TITLE"),
        ],
    )


# ------------------------------------------------------------------- comments


def command_comments_list(context: Context) -> int:
    limit = validate_limit(context.args.limit)
    # Checked before the call because Google refuses this filter under the
    # read-only scope, and a refused call still costs a quota unit.
    context.session.require_scope(oauth.SCOPE_YOUTUBE_FORCE_SSL, capability="comments-read")
    identity = context.guarded_channel()
    threads = context.api.list_comment_threads(identity.channel_id, limit=limit)

    if context.args.unanswered:
        records = comments_module.select_unanswered(
            threads, identity.channel_id, include_uncertain=context.args.include_uncertain
        )
        mode = "unanswered"
    else:
        records = [
            comments_module.summarise_thread(
                thread, comments_module.classify_thread(thread, identity.channel_id)
            )
            for thread in threads
        ]
        mode = "all"

    payload = {
        "channel_id": identity.channel_id,
        "mode": mode,
        "limit": limit,
        "threads_inspected": len(threads),
        "returned": len(records),
        "uncertain_included": bool(context.args.unanswered and context.args.include_uncertain),
        "comments": records,
    }
    context.printer.emit(payload, _render_comments)
    return EXIT_OK


def _render_comments(printer: Printer, payload: dict[str, Any]) -> None:
    printer.line(
        f"channel {payload['channel_id']}: inspected {payload['threads_inspected']} threads, "
        f"{payload['returned']} shown ({payload['mode']})"
    )
    uncertain = [record for record in payload["comments"] if record["state"] == comments_module.UNCERTAIN]
    if uncertain:
        printer.line(
            f"{len(uncertain)} thread(s) had truncated reply data and could not be classified with "
            "certainty; they are listed as uncertain."
        )
    printer.line()
    rows = [
        {
            "comment_id": record.get("comment_id"),
            "state": record.get("state"),
            "published": (record.get("published_at") or "-")[:10],
            "author": truncate(record.get("author"), 20),
            "text": truncate(record.get("text"), 48),
        }
        for record in payload["comments"]
    ]
    printer.table(
        rows,
        [
            ("comment_id", "COMMENT ID"),
            ("state", "STATE"),
            ("published", "PUBLISHED"),
            ("author", "AUTHOR"),
            ("text", "TEXT"),
        ],
    )


def command_comments_reply(context: Context) -> int:
    text = _read_text_file(Path(context.args.text_file), "reply")
    plan = operations.plan_comment_reply(context.args.comment_id, text)
    identity = context.guarded_channel()

    # Checked in the dry run too, so the operator sees the resolved target
    # before deciding, and a foreign target is refused without --apply.
    target = context.api.resolve_reply_target(context.args.comment_id, identity.channel_id)
    parent_id = _canonical_reply_parent(target)
    plan.payload["parent_id"] = parent_id
    plan.target = f"comment {parent_id} on {target['basis']}"
    plan.notes.insert(
        0,
        f"target verified: owned by {target['owner_channel_id']}"
        + (f", video {target['video_id']}" if target["video_id"] else ""),
    )
    if parent_id != target["comment_id"]:
        plan.notes.insert(
            1,
            f"{target['comment_id']} is itself a reply, so the reply is attached to its "
            f"top-level comment {parent_id}",
        )
    if target["author"]:
        plan.notes.insert(1, f"replying to {target['author']}")

    if not context.args.apply:
        _emit_plan(context, plan, applied=False)
        return EXIT_OK

    context.session.require_scope(oauth.SCOPE_YOUTUBE_FORCE_SSL, capability="comment-reply")
    verified = context.guarded_channel(force=True)
    confirmed = context.api.resolve_reply_target(context.args.comment_id, verified.channel_id)
    result = context.api.insert_comment_reply(
        _canonical_reply_parent(confirmed), plan.payload["text"]
    )
    _emit_plan(
        context,
        plan,
        applied=True,
        extra={"channel_id": verified.channel_id, "comment_id": result.get("id")},
    )
    return EXIT_OK


# ------------------------------------------------------------------ analytics


def command_analytics_summary(context: Context) -> int:
    days = context.args.days
    if days < 1 or days > 365:
        raise UsageError(f"--days must be between 1 and 365, got {days}")

    identity = context.guarded_channel()
    end = dt.datetime.now(dt.timezone.utc).date()
    start = end - dt.timedelta(days=days - 1)
    report = context.api.analytics_report(
        identity.channel_id, start.isoformat(), end.isoformat()
    )

    headers = [column.get("name") for column in report.get("columnHeaders", [])]
    rows = report.get("rows") or []
    metrics = dict(zip(headers, rows[0])) if rows else {name: None for name in headers}
    payload = {
        "channel_id": identity.channel_id,
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "days_requested": days,
        "metrics": metrics,
        "rows_returned": len(rows),
        "note": (
            "The API returns data up to the last day for which every requested metric is "
            "available, which is usually behind the end date."
        ),
    }
    context.printer.emit(payload, _render_analytics)
    return EXIT_OK


def _render_analytics(printer: Printer, payload: dict[str, Any]) -> None:
    printer.line(
        f"channel {payload['channel_id']}: {payload['start_date']} to {payload['end_date']} "
        f"({payload['days_requested']} days requested)"
    )
    printer.line()
    if not payload["rows_returned"]:
        printer.line("(the API returned no rows for this window)")
    for name, value in payload["metrics"].items():
        printer.field(name, value, width=26)
    printer.line()
    printer.line(payload["note"])


# ----------------------------------------------------------------------- auth


def command_auth_login(context: Context) -> int:
    printer = context.printer
    capabilities = list(context.args.enable or ())
    scopes = oauth.scopes_for(capabilities)
    credentials = ClientCredentials.load()

    printer.line("This authorises the CLI against one YouTube channel.")
    printer.line(f"Choose the {CHANNEL_TITLE} channel ({CHANNEL_HANDLE}) at the account picker.")
    printer.line()
    printer.line("Requested scopes:")
    for description in oauth.describe_scopes(scopes):
        printer.line(f"  {description}")
    if capabilities:
        printer.line()
        printer.line("Capabilities requested deliberately:")
        for capability in capabilities:
            printer.line(f"  {capability}: {oauth.CAPABILITIES[capability][1]}")
        widening = [name for name in capabilities if name in oauth.WRITE_CAPABILITIES]
        if widening:
            printer.line()
            printer.line(f"This grant allows changes to the channel: {', '.join(widening)}.")
    printer.line()

    request = oauth.start_login(credentials, scopes)
    printer.line("Open this URL in the browser signed in as the channel owner:")
    printer.line()
    printer.line(request.authorisation_url)
    printer.line()
    printer.line(f"Waiting up to {int(oauth.LOGIN_TIMEOUT_SECONDS)} seconds for the redirect ...")

    if not context.args.no_browser:
        try:
            webbrowser.open(request.authorisation_url)
        except Exception:  # noqa: BLE001 - a headless box simply shows the URL
            pass

    code = oauth.await_authorisation_code(request)
    state = oauth.exchange_code(
        context.transport, credentials, request, code, capabilities=capabilities
    )

    # Verify before storing. A grant for the wrong channel is withdrawn rather
    # than left on disk, where it would be an unusable and possibly wider
    # authorisation than the operator intended.
    probe = YouTubeApi(context.transport, lambda: str(state.access_token))
    try:
        identity = probe.my_channel()
        warnings = channel_module.verify(identity)
    except CliError:
        oauth.post_revocation(context.transport, state.refresh_token)
        printer.warn("the new authorisation was revoked and no token was stored")
        raise
    for warning in warnings:
        printer.warn(warning)

    context.session.persist(state)
    payload = {
        "authorised": True,
        "channel_id": identity.channel_id,
        "title": identity.title,
        "handle": identity.handle,
        "scopes": list(state.scopes),
        "token_path": str(context.session.token_path),
        "token_mode": storage.describe_permissions(context.session.token_path),
    }
    printer.emit(payload, _render_login)
    return EXIT_OK


def _render_login(printer: Printer, payload: dict[str, Any]) -> None:
    printer.line()
    printer.line("Authorisation stored.")
    printer.field("channel ID", payload["channel_id"])
    printer.field("title", payload["title"])
    printer.field("handle", payload["handle"])
    printer.field("token file", f"{payload['token_path']} ({payload['token_mode']})")
    for scope in payload["scopes"]:
        printer.line(f"  scope: {scope}")


def command_auth_status(context: Context) -> int:
    state = context.session.stored_state()
    payload = {
        **oauth.dump_state_for_display(state),
        "token_path": str(context.session.token_path),
        "token_mode": storage.describe_permissions(context.session.token_path),
        "client_secret_path": str(storage.client_secret_path()),
        "client_secret_mode": storage.describe_permissions(storage.client_secret_path()),
        "capabilities_granted": list(state.capabilities) if state else [],
        "write_capabilities_granted": sorted(
            name for name in (state.capabilities if state else ()) if name in oauth.WRITE_CAPABILITIES
        ),
    }
    context.printer.emit(payload, _render_auth_status)
    return EXIT_OK if state else EXIT_AUTH_REQUIRED


def _render_auth_status(printer: Printer, payload: dict[str, Any]) -> None:
    printer.field("authorised", payload.get("authorised", False))
    printer.field("token file", f"{payload['token_path']} ({payload['token_mode']})")
    printer.field("client secret", f"{payload['client_secret_path']} ({payload['client_secret_mode']})")
    if payload.get("authorised"):
        printer.field("access token expires", payload.get("access_token_expires_at"))
        printer.field("obtained at", payload.get("obtained_at"))
        for scope in payload.get("scopes", []):
            printer.line(f"  scope: {scope}")
        granted = payload["capabilities_granted"]
        printer.field("capabilities", ", ".join(granted) if granted else "none (read-only)")
        writes = payload["write_capabilities_granted"]
        printer.field("write capabilities", ", ".join(writes) if writes else "none (read-only)")
    else:
        printer.line("no stored authorisation; run 'nexttang-youtube auth login'")


def command_auth_revoke(context: Context) -> int:
    result = context.session.revoke()
    context.printer.emit(result, _render_revoke)
    return EXIT_OK


def _render_revoke(printer: Printer, payload: dict[str, Any]) -> None:
    printer.field("revoked at Google", payload.get("revoked"))
    printer.field("local token removed", payload.get("local_state_removed"))
    if payload.get("reason"):
        printer.field("reason", payload["reason"])


# ------------------------------------------------------------------- plumbing


def _emit_plan(
    context: Context,
    plan: operations.Plan,
    *,
    applied: bool,
    extra: dict[str, Any] | None = None,
) -> None:
    printer = context.printer
    payload = {**plan.as_dict(), "applied": applied, "dry_run": not applied, **(extra or {})}
    if printer.json_output:
        printer.emit(payload, lambda *_: None)
        return

    printer.line("APPLIED" if applied else "DRY RUN")
    printer.field("operation", plan.operation)
    printer.field("target", plan.target)
    printer.field("summary", plan.summary)
    if plan.request:
        printer.section("Request")
        for key, value in plan.request.items():
            printer.field(key, value)
    if plan.diff:
        printer.section("Change")
        for line in plan.diff:
            printer.line(line)
    if plan.notes:
        printer.section("Notes")
        for note in plan.notes:
            printer.line(f"- {note}")
    printer.line()
    if not applied:
        printer.line("No request was sent. Re-run with --apply to perform this change.")
    else:
        printer.line("The change was applied.")


def _canonical_reply_parent(target: dict[str, Any]) -> str:
    """Resolve the thread's top-level comment.

    YouTube threads are one level deep. Passing a reply's own ID as parentId
    does not attach the new comment where the operator meant, so when the given
    comment is itself a reply the thread's top-level parent is used instead.
    """
    return target.get("parent_id") or target["comment_id"]


def _describe_file(mode: str) -> str:
    """Describe a stored file by presence and permissions, never by content."""
    return "absent" if mode == "absent" else f"present (mode {mode})"


def _read_text_file(path: Path, label: str) -> str:
    if not path.exists():
        raise UsageError(f"{label} file not found: {path}")
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise UsageError(f"{label} file is not UTF-8 text: {path}") from exc


def _optional_text(path_value: str | None) -> str:
    if not path_value:
        return ""
    return _read_text_file(Path(path_value), "description")


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--json", action="store_true", dest="json_output", help="emit machine-readable JSON"
    )

    apply_flag = argparse.ArgumentParser(add_help=False)
    apply_flag.add_argument(
        "--apply",
        action="store_true",
        help="perform the change; without this flag the command is a dry run",
    )

    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description=f"Read-first CLI for the pinned NextTang YouTube channel ({CHANNEL_ID}).",
    )
    parser.add_argument("--version", action="version", version=f"{PROGRAM} {__version__}")
    groups = parser.add_subparsers(dest="group", required=True)

    status = groups.add_parser("status", parents=[common], help="report readiness and channel identity")
    status.add_argument("--offline", action="store_true", help="skip the API channel resolution")
    status.set_defaults(handler=command_status)

    channel = groups.add_parser("channel", help="channel level commands")
    channel_commands = channel.add_subparsers(dest="command", required=True)
    channel_show = channel_commands.add_parser("show", parents=[common], help="show channel details")
    channel_show.set_defaults(handler=command_channel_show)
    channel_description = channel_commands.add_parser(
        "set-description",
        parents=[common, apply_flag],
        help="replace the channel description from a file (dry run by default)",
    )
    channel_description.add_argument("--file", required=True, help="UTF-8 file holding the new description")
    channel_description.set_defaults(handler=command_channel_set_description)
    channel_banner = channel_commands.add_parser(
        "set-banner",
        parents=[common, apply_flag],
        help="upload and set channel banner artwork (dry run by default)",
    )
    channel_banner.add_argument("--file", required=True, help="2048x1152 or larger 16:9 PNG/JPEG")
    channel_banner.set_defaults(handler=command_channel_set_banner)
    channel_watermark = channel_commands.add_parser(
        "set-watermark",
        parents=[common, apply_flag],
        help="upload and set the channel-wide video watermark (dry run by default)",
    )
    channel_watermark.add_argument("--file", required=True, help="150x150 PNG/JPEG watermark")
    channel_watermark.set_defaults(handler=command_channel_set_watermark)

    videos = groups.add_parser("videos", help="video commands")
    video_commands = videos.add_subparsers(dest="command", required=True)
    videos_list = video_commands.add_parser("list", parents=[common], help="list uploads")
    videos_list.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help=f"maximum records to return (default {DEFAULT_LIMIT}, ceiling {MAX_LIMIT})",
    )
    videos_list.add_argument(
        "--details",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="fetch privacy status and statistics for the listed videos",
    )
    videos_list.set_defaults(handler=command_videos_list)

    videos_upload = video_commands.add_parser(
        "upload", parents=[common, apply_flag], help="upload a video as private (dry run by default)"
    )
    videos_upload.add_argument("path", help="path to the video file")
    videos_upload.add_argument(
        "--privacy",
        required=True,
        help="required and must be 'private'; this CLI does not publish",
    )
    videos_upload.add_argument("--title", help="video title (defaults to the file stem)")
    videos_upload.add_argument("--description-file", help="UTF-8 file holding the video description")
    videos_upload.set_defaults(handler=command_videos_upload)

    playlists = groups.add_parser("playlists", help="playlist commands")
    playlist_commands = playlists.add_subparsers(dest="command", required=True)
    playlists_list = playlist_commands.add_parser("list", parents=[common], help="list playlists")
    playlists_list.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help=f"maximum records to return (default {DEFAULT_LIMIT}, ceiling {MAX_LIMIT})",
    )
    playlists_list.set_defaults(handler=command_playlists_list)

    comments = groups.add_parser("comments", help="comment commands")
    comment_commands = comments.add_subparsers(dest="command", required=True)
    comments_list = comment_commands.add_parser("list", parents=[common], help="list comment threads")
    comments_list.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help=f"maximum threads to inspect (default {DEFAULT_LIMIT}, ceiling {MAX_LIMIT})",
    )
    comments_list.add_argument(
        "--unanswered", action="store_true", help="show only threads the channel has not replied to"
    )
    comments_list.add_argument(
        "--include-uncertain",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="include threads whose reply data was truncated by the API",
    )
    comments_list.set_defaults(handler=command_comments_list)

    comments_reply = comment_commands.add_parser(
        "reply", parents=[common, apply_flag], help="reply to one comment (dry run by default)"
    )
    comments_reply.add_argument("comment_id", help="the comment ID to reply to")
    comments_reply.add_argument("--text-file", required=True, help="UTF-8 file holding the reply")
    comments_reply.set_defaults(handler=command_comments_reply)

    analytics = groups.add_parser("analytics", help="analytics commands")
    analytics_commands = analytics.add_subparsers(dest="command", required=True)
    analytics_summary = analytics_commands.add_parser(
        "summary", parents=[common], help="summarise channel analytics"
    )
    analytics_summary.add_argument(
        "--days", type=int, default=28, help="window length in days ending today (default 28)"
    )
    analytics_summary.set_defaults(handler=command_analytics_summary)

    auth = groups.add_parser("auth", help="authorisation commands")
    auth_commands = auth.add_subparsers(dest="command", required=True)
    auth_login = auth_commands.add_parser(
        "login", parents=[common], help="authorise this CLI for the NextTang channel"
    )
    auth_login.add_argument(
        "--enable",
        action="append",
        choices=sorted(oauth.CAPABILITIES),
        help="deliberately request one extra capability; repeatable",
    )
    auth_login.add_argument("--no-browser", action="store_true", help="print the URL without opening it")
    auth_login.set_defaults(handler=command_auth_login)

    auth_status = auth_commands.add_parser(
        "status", parents=[common], help="show stored authorisation without contacting the API"
    )
    auth_status.set_defaults(handler=command_auth_status)

    auth_revoke = auth_commands.add_parser(
        "revoke", parents=[common], help="revoke at Google and delete the local token"
    )
    auth_revoke.set_defaults(handler=command_auth_revoke)

    return parser


def main(argv: Sequence[str] | None = None, *, transport: Transport | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    printer = Printer(json_output=getattr(args, "json_output", False))
    context = Context(args=args, printer=printer, transport=transport or UrllibTransport())

    try:
        return int(args.handler(context))
    except CliError as error:
        printer.error(error.message)
        if error.hint:
            printer.hint(error.hint)
        return error.exit_code
    except KeyboardInterrupt:
        printer.error("interrupted; no change was applied")
        return 130


if __name__ == "__main__":
    sys.exit(main())
