"""End-to-end CLI behaviour against a mocked transport.

These tests are the guarantee that a dry run cannot mutate the channel and that
no command touches a channel other than the pinned one.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from youtube_support import (
    CHANNEL_ID,
    OTHER_CHANNEL_ID,
    FakeTransport,
    branding_resource,
    channel_resource,
    comment_thread,
    error_payload,
)

from nexttang_youtube import oauth, redaction, storage
from nexttang_youtube.cli import main
from nexttang_youtube.errors import (
    EXIT_AUTH_REQUIRED,
    EXIT_CHANNEL_MISMATCH,
    EXIT_NO_CREDENTIALS,
    EXIT_OK,
    EXIT_QUOTA,
)


@contextlib.contextmanager
def captured():
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        yield out, err


class CliTestCase(unittest.TestCase):
    """Isolated configuration directory, no live network, no shared secrets."""

    scopes = list(oauth.READ_ONLY_SCOPES)

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.config = Path(self.temporary.name) / "config"
        patcher = mock.patch.dict(os.environ, {storage.CONFIG_DIR_ENV: str(self.config)})
        patcher.start()
        self.addCleanup(patcher.stop)
        redaction.forget_secrets()
        self.addCleanup(redaction.forget_secrets)
        self.write_credentials()

    capabilities: list[str] = []

    def write_credentials(
        self,
        *,
        scopes: list[str] | None = None,
        token: bool = True,
        capabilities: list[str] | None = None,
    ) -> None:
        storage.write_secret_json(
            storage.client_secret_path(),
            {
                "installed": {
                    "client_id": "123456789012-testclient.apps.googleusercontent.com",
                    "client_secret": "GOCSPX-test-client-secret-value",
                    "redirect_uris": ["http://localhost"],
                }
            },
        )
        if token:
            storage.write_secret_json(
                storage.token_path(),
                {
                    "refresh_token": "1//04-test-refresh-token-value",
                    "access_token": "ya29.test-access-token-value",
                    "expires_at": time.time() + 3600,
                    "scopes": scopes if scopes is not None else self.scopes,
                    "capabilities": capabilities if capabilities is not None else self.capabilities,
                    "token_type": "Bearer",
                    "client_id": "123456789012-testclient.apps.googleusercontent.com",
                },
            )

    def run_cli(self, argv: list[str], transport: FakeTransport) -> tuple[int, str, str]:
        with captured() as (out, err):
            code = main(argv, transport=transport)
        return code, out.getvalue(), err.getvalue()


class ReadCommandTests(CliTestCase):
    def test_status_verifies_the_pinned_channel(self) -> None:
        transport = FakeTransport().route("GET", "mine=true", payload=channel_resource())
        code, out, _ = self.run_cli(["status"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertIn(CHANNEL_ID, out)
        self.assertIn("verified against the pinned channel ID", out)
        self.assertEqual(transport.mutating_requests, [])

    def test_status_offline_makes_no_api_call(self) -> None:
        transport = FakeTransport()
        code, out, _ = self.run_cli(["status", "--offline"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertEqual(transport.requests, [])
        self.assertIn("skipped", out)

    def test_status_without_a_client_credential_reports_the_blocker(self) -> None:
        storage.remove(storage.client_secret_path())
        code, out, _ = self.run_cli(["status", "--offline"], FakeTransport())
        self.assertEqual(code, EXIT_NO_CREDENTIALS)
        self.assertIn("no OAuth client credential", out)

    def test_status_without_authorisation_reports_the_blocker(self) -> None:
        storage.remove(storage.token_path())
        code, out, _ = self.run_cli(["status", "--offline"], FakeTransport())
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("auth login", out)

    def test_channel_show_reports_the_description(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route("GET", "brandingSettings", payload=branding_resource())
        code, out, _ = self.run_cli(["channel", "show"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertIn("Original description", out)
        self.assertEqual(transport.mutating_requests, [])

    def test_videos_list_defaults_to_twenty_five(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "playlistItems",
            payload={
                "items": [
                    {
                        "snippet": {"title": "Devlog 001"},
                        "contentDetails": {"videoId": "vid001", "videoPublishedAt": "2026-08-01T00:00:00Z"},
                    }
                ]
            },
        )
        transport.route(
            "GET",
            "/videos",
            payload={"items": [{"id": "vid001", "status": {"privacyStatus": "private"}, "statistics": {"viewCount": "7"}}]},
        )
        code, out, _ = self.run_cli(["videos", "list"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertIn("vid001", out)
        self.assertIn("private", out)
        self.assertEqual(transport.query_values("playlistItems", "maxResults"), ["25"])

    def test_videos_list_rejects_an_over_large_limit(self) -> None:
        transport = FakeTransport().route("GET", "mine=true", payload=channel_resource())
        code, _, err = self.run_cli(["videos", "list", "--limit", "5000"], transport)
        self.assertNotEqual(code, EXIT_OK)
        self.assertIn("ceiling", err)

    def test_playlists_list_is_bounded(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "/playlists",
            payload={"items": [{"id": "PL1", "snippet": {"title": "Devlogs"}, "contentDetails": {"itemCount": 2}}]},
        )
        code, out, _ = self.run_cli(["playlists", "list", "--limit", "10"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertIn("PL1", out)
        self.assertEqual(transport.query_values("/playlists", "maxResults"), ["10"])

    def test_comments_need_the_comments_read_capability(self) -> None:
        transport = FakeTransport()
        code, _, err = self.run_cli(["comments", "list", "--unanswered"], transport)
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("auth login --enable comments-read", err)
        self.assertEqual(transport.requests, [], "the scope is checked before any quota is spent")

    def test_comments_unanswered_filters_and_flags_uncertainty(self) -> None:
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_FORCE_SSL],
            capabilities=["comments-read"],
        )
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "commentThreads",
            payload={
                "items": [
                    comment_thread("t1", text="Will this work on a 60K?"),
                    comment_thread("t2", total_replies=1, reply_authors=(CHANNEL_ID,)),
                    comment_thread("t3", total_replies=9, reply_authors=("UCother",)),
                ]
            },
        )
        code, out, _ = self.run_cli(["comments", "list", "--unanswered", "--json"], transport)
        self.assertEqual(code, EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["mode"], "unanswered")
        self.assertEqual([record["thread_id"] for record in payload["comments"]], ["t1", "t3"])
        self.assertFalse(payload["comments"][1]["reply_data_complete"])

    def test_analytics_summary_queries_the_pinned_channel(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "youtubeanalytics",
            payload={
                "columnHeaders": [{"name": "views"}, {"name": "likes"}],
                "rows": [[128, 9]],
            },
        )
        code, out, _ = self.run_cli(["analytics", "summary", "--days", "28", "--json"], transport)
        self.assertEqual(code, EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["metrics"], {"views": 128, "likes": 9})
        analytics_call = transport.calls_to("youtubeanalytics")[0]
        self.assertIn(f"channel%3D%3D{CHANNEL_ID}", analytics_call.url)

    def test_analytics_rejects_an_out_of_range_window(self) -> None:
        transport = FakeTransport()
        code, _, err = self.run_cli(["analytics", "summary", "--days", "0"], transport)
        self.assertNotEqual(code, EXIT_OK)
        self.assertIn("--days", err)


class ChannelGuardCliTests(CliTestCase):
    def test_a_different_channel_stops_the_command(self) -> None:
        transport = FakeTransport().route(
            "GET", "mine=true", payload=channel_resource(channel_id=OTHER_CHANNEL_ID, title="jonattree")
        )
        code, _, err = self.run_cli(["videos", "list"], transport)
        self.assertEqual(code, EXIT_CHANNEL_MISMATCH)
        self.assertIn(OTHER_CHANNEL_ID, err)
        self.assertIn(CHANNEL_ID, err)
        self.assertEqual(len(transport.requests), 1, "nothing runs after the identity check fails")

    def test_a_renamed_channel_warns_but_proceeds(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource(title="NextTang FPGA"))
        transport.route("GET", "brandingSettings", payload=branding_resource())
        code, out, err = self.run_cli(["channel", "show"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertIn("warning:", err)
        self.assertIn("pinned channel ID still matches", err)
        self.assertIn(CHANNEL_ID, out)

    def test_quota_exhaustion_is_reported_distinctly(self) -> None:
        transport = FakeTransport().route(
            "GET", "mine=true", status=403, payload=error_payload(403, "quotaExceeded")
        )
        code, _, err = self.run_cli(["videos", "list"], transport)
        self.assertEqual(code, EXIT_QUOTA)
        self.assertIn("quota", err.lower())


class DryRunTests(CliTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.description = Path(self.temporary.name) / "description.txt"
        self.description.write_text("A new channel description for NextTang.\n", encoding="utf-8")
        self.reply = Path(self.temporary.name) / "reply.txt"
        self.reply.write_text("Thanks. The 138K board is still in transit.\n", encoding="utf-8")
        self.video = Path(self.temporary.name) / "devlog-001.mp4"
        self.video.write_bytes(b"\x00" * 4096)

    def _read_routes(self) -> FakeTransport:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route("GET", "brandingSettings", payload=branding_resource())
        return transport

    def _reply_routes(self, owner: str = CHANNEL_ID) -> FakeTransport:
        """Routes for a reply whose target resolves to our own video."""
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "/comments",
            payload={
                "items": [
                    {
                        "id": "Ugx123",
                        "snippet": {
                            "videoId": "vid123",
                            "channelId": owner,
                            "authorDisplayName": "A Viewer",
                            "textOriginal": "nice work",
                        },
                    }
                ]
            },
        )
        transport.route(
            "GET", "/videos", payload={"items": [{"id": "vid123", "snippet": {"channelId": owner}}]}
        )
        return transport

    def test_set_description_dry_run_sends_no_write(self) -> None:
        transport = self._read_routes()
        code, out, _ = self.run_cli(
            ["channel", "set-description", "--file", str(self.description)], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("DRY RUN", out)
        self.assertIn("Re-run with --apply", out)
        self.assertEqual(transport.mutating_requests, [])

    def test_dry_run_shows_the_before_and_after_diff(self) -> None:
        transport = self._read_routes()
        _, out, _ = self.run_cli(
            ["channel", "set-description", "--file", str(self.description)], transport
        )
        self.assertIn("-Original description", out)
        self.assertIn("+A new channel description for NextTang.", out)

    def test_dry_run_names_the_fields_it_will_preserve(self) -> None:
        transport = self._read_routes()
        _, out, _ = self.run_cli(
            ["channel", "set-description", "--file", str(self.description)], transport
        )
        self.assertIn("keywords", out)
        self.assertIn("unsubscribedTrailer", out)

    def test_upload_dry_run_sends_no_write(self) -> None:
        transport = FakeTransport().route("GET", "mine=true", payload=channel_resource())
        code, out, _ = self.run_cli(
            ["videos", "upload", str(self.video), "--privacy", "private"], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("DRY RUN", out)
        self.assertEqual(transport.mutating_requests, [])

    def test_upload_requires_an_explicit_privacy_value(self) -> None:
        transport = FakeTransport()
        with self.assertRaises(SystemExit) as raised:
            with captured():
                main(["videos", "upload", str(self.video)], transport=transport)
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(transport.requests, [])

    def test_upload_refuses_a_public_privacy_value(self) -> None:
        transport = FakeTransport()
        code, _, err = self.run_cli(
            ["videos", "upload", str(self.video), "--privacy", "public"], transport
        )
        self.assertNotEqual(code, EXIT_OK)
        self.assertIn("only as private", err)
        self.assertEqual(transport.requests, [], "the policy is enforced before any API call")

    def test_comment_reply_dry_run_sends_no_write(self) -> None:
        transport = self._reply_routes()
        code, out, _ = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply)], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("DRY RUN", out)
        self.assertEqual(transport.mutating_requests, [])

    def test_dry_run_works_with_read_only_authorisation(self) -> None:
        self.write_credentials(scopes=list(oauth.READ_ONLY_SCOPES))
        transport = self._read_routes()
        code, _, _ = self.run_cli(
            ["channel", "set-description", "--file", str(self.description)], transport
        )
        self.assertEqual(code, EXIT_OK)


class ApplyTests(DryRunTests):
    def test_apply_without_the_write_scope_is_refused(self) -> None:
        self.write_credentials(scopes=list(oauth.READ_ONLY_SCOPES))
        transport = self._read_routes()
        code, _, err = self.run_cli(
            ["channel", "set-description", "--file", str(self.description), "--apply"], transport
        )
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("auth login --enable channel-write", err)
        self.assertEqual(transport.mutating_requests, [])

    def test_a_shared_scope_does_not_enable_an_unrequested_capability(self) -> None:
        """force-ssl backs both comments-read and comment-reply.

        Granting it for reading must not silently authorise replying.
        """
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_FORCE_SSL],
            capabilities=["comments-read"],
        )
        transport = self._reply_routes()
        transport.route("POST", "/comments", payload={"id": "should-not-happen"})
        code, _, err = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply), "--apply"], transport
        )
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("was not requested at login", err)
        self.assertEqual(transport.mutating_requests, [])

    def test_apply_writes_the_complete_branding_object(self) -> None:
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_MANAGE],
            capabilities=["channel-write"],
        )
        transport = self._read_routes()
        transport.route("PUT", "/channels", payload={"id": CHANNEL_ID})

        code, out, _ = self.run_cli(
            ["channel", "set-description", "--file", str(self.description), "--apply"], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("APPLIED", out)

        writes = transport.mutating_requests
        self.assertEqual(len(writes), 1)
        body = writes[0].json_body()
        self.assertEqual(body["id"], CHANNEL_ID)
        self.assertIn("part=brandingSettings", writes[0].url)
        channel_block = body["brandingSettings"]["channel"]
        self.assertEqual(channel_block["description"], "A new channel description for NextTang.\n")
        self.assertEqual(channel_block["keywords"], "fpga tang zxspectrumnext")
        self.assertEqual(channel_block["country"], "GB")
        self.assertEqual(channel_block["unsubscribedTrailer"], "abcdefghijk")
        self.assertEqual(body["brandingSettings"]["image"]["bannerExternalUrl"], "https://example.invalid/banner")

    def test_apply_re_resolves_the_channel_immediately_before_writing(self) -> None:
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_MANAGE],
            capabilities=["channel-write"],
        )
        transport = self._read_routes()
        transport.route("PUT", "/channels", payload={"id": CHANNEL_ID})
        self.run_cli(
            ["channel", "set-description", "--file", str(self.description), "--apply"], transport
        )

        identity_calls = [
            index for index, request in enumerate(transport.requests) if "mine=true" in request.url
        ]
        write_index = next(
            index for index, request in enumerate(transport.requests) if request.method == "PUT"
        )
        self.assertGreaterEqual(len(identity_calls), 2, "the channel is re-resolved before the write")
        self.assertLess(identity_calls[-1], write_index)

    def test_apply_stops_when_the_channel_changed_since_the_plan(self) -> None:
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_MANAGE],
            capabilities=["channel-write"],
        )
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route("GET", "brandingSettings", payload=branding_resource(), times=1)
        transport.route(
            "GET", "brandingSettings", payload=branding_resource(description="Changed elsewhere"), times=1
        )
        transport.route("PUT", "/channels", payload={"id": CHANNEL_ID})

        code, _, err = self.run_cli(
            ["channel", "set-description", "--file", str(self.description), "--apply"], transport
        )
        self.assertNotEqual(code, EXIT_OK)
        self.assertIn("changed between the plan and the apply step", err)
        self.assertEqual(transport.mutating_requests, [])

    def test_apply_on_a_mismatched_channel_never_writes(self) -> None:
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_MANAGE],
            capabilities=["channel-write"],
        )
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource(channel_id=OTHER_CHANNEL_ID))
        transport.route("PUT", "/channels", payload={"id": OTHER_CHANNEL_ID})
        code, _, _ = self.run_cli(
            ["channel", "set-description", "--file", str(self.description), "--apply"], transport
        )
        self.assertEqual(code, EXIT_CHANNEL_MISMATCH)
        self.assertEqual(transport.mutating_requests, [])

    def test_comment_reply_apply_posts_one_reply(self) -> None:
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_FORCE_SSL],
            capabilities=["comment-reply"],
        )
        transport = self._reply_routes()
        transport.route("POST", "/comments", payload={"id": "Ugx123.reply"})
        code, out, _ = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply), "--apply"], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("APPLIED", out)
        writes = transport.mutating_requests
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0].json_body()["snippet"]["parentId"], "Ugx123")

    def test_upload_apply_sends_private_status(self) -> None:
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_UPLOAD],
            capabilities=["upload"],
        )
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "POST",
            "/upload/youtube/v3/videos",
            payload={},
            headers={"Location": "https://www.googleapis.com/upload/session/abc"},
        )
        transport.route(
            "PUT",
            "/upload/session/abc",
            payload={"id": "newvid", "status": {"privacyStatus": "private"}},
        )
        code, out, _ = self.run_cli(
            ["videos", "upload", str(self.video), "--privacy", "private", "--apply"], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("APPLIED", out)
        session_request = transport.calls_to("/upload/youtube/v3/videos")[0]
        self.assertEqual(session_request.json_body()["status"]["privacyStatus"], "private")
        self.assertIn("uploadType=resumable", session_request.url)


class ReplyTargetTests(CliTestCase):
    """A reply must land on NextTang's own content, not merely be spoken by it."""

    def setUp(self) -> None:
        super().setUp()
        self.reply = Path(self.temporary.name) / "reply.txt"
        self.reply.write_text("Thanks, the board is still in transit.\n", encoding="utf-8")
        self.write_credentials(
            scopes=[*oauth.READ_ONLY_SCOPES, oauth.SCOPE_YOUTUBE_FORCE_SSL],
            capabilities=["comment-reply"],
        )

    def _transport(self, *, owner: str, video_id: str | None = "vid123") -> FakeTransport:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "/comments",
            payload={
                "items": [
                    {
                        "id": "Ugx123",
                        "snippet": {
                            "videoId": video_id,
                            "channelId": owner,
                            "authorDisplayName": "A Viewer",
                            "textOriginal": "nice work",
                        },
                    }
                ]
            },
        )
        if video_id:
            transport.route(
                "GET",
                "/videos",
                payload={"items": [{"id": video_id, "snippet": {"channelId": owner}}]},
            )
        transport.route("POST", "/comments", payload={"id": "Ugx123.reply"})
        return transport

    def test_a_reply_to_another_channels_video_is_refused_on_apply(self) -> None:
        transport = self._transport(owner=OTHER_CHANNEL_ID)
        code, _, err = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply), "--apply"], transport
        )
        self.assertEqual(code, EXIT_CHANNEL_MISMATCH)
        self.assertIn(OTHER_CHANNEL_ID, err)
        self.assertEqual(transport.mutating_requests, [], "no reply may be posted")

    def test_a_foreign_target_is_refused_during_the_dry_run_too(self) -> None:
        transport = self._transport(owner=OTHER_CHANNEL_ID)
        code, _, err = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply)], transport
        )
        self.assertEqual(code, EXIT_CHANNEL_MISMATCH)
        self.assertIn("only replies to comments on its own", err)

    def test_a_reply_on_our_own_video_is_allowed(self) -> None:
        transport = self._transport(owner=CHANNEL_ID)
        code, out, _ = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply), "--apply"], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("APPLIED", out)
        self.assertEqual(len(transport.mutating_requests), 1)

    def test_the_dry_run_shows_the_resolved_target(self) -> None:
        transport = self._transport(owner=CHANNEL_ID)
        code, out, _ = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply)], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("target verified", out)
        self.assertIn("vid123", out)
        self.assertIn("A Viewer", out)
        self.assertEqual(transport.mutating_requests, [])

    def test_an_unresolvable_video_is_refused(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "/comments",
            payload={"items": [{"id": "Ugx123", "snippet": {"videoId": "gone", "channelId": CHANNEL_ID}}]},
        )
        transport.route("GET", "/videos", payload={"items": []})
        transport.route("POST", "/comments", payload={"id": "should-not-happen"})

        code, _, err = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply), "--apply"], transport
        )
        self.assertEqual(code, EXIT_CHANNEL_MISMATCH)
        self.assertIn("could not be resolved", err)
        self.assertEqual(transport.mutating_requests, [])

    def _reply_to_a_reply(self, owner: str = CHANNEL_ID) -> FakeTransport:
        """The supplied ID is itself a reply, whose parent is the top-level comment."""
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "/comments",
            payload={
                "items": [
                    {
                        "id": "reply-comment",
                        "snippet": {
                            "videoId": "vid123",
                            "channelId": owner,
                            "parentId": "top-level-comment",
                            "authorDisplayName": "A Viewer",
                            "textOriginal": "a reply",
                        },
                    }
                ]
            },
        )
        transport.route(
            "GET", "/videos", payload={"items": [{"id": "vid123", "snippet": {"channelId": owner}}]}
        )
        transport.route("POST", "/comments", payload={"id": "new-reply"})
        return transport

    def test_replying_to_a_reply_targets_the_top_level_comment(self) -> None:
        transport = self._reply_to_a_reply()
        code, _, _ = self.run_cli(
            ["comments", "reply", "reply-comment", "--text-file", str(self.reply), "--apply"],
            transport,
        )
        self.assertEqual(code, EXIT_OK)
        posted = transport.mutating_requests[0].json_body()
        self.assertEqual(
            posted["snippet"]["parentId"],
            "top-level-comment",
            "a thread is one level deep, so the reply attaches to the top-level comment",
        )

    def test_the_dry_run_explains_the_retargeting(self) -> None:
        transport = self._reply_to_a_reply()
        code, out, _ = self.run_cli(
            ["comments", "reply", "reply-comment", "--text-file", str(self.reply)], transport
        )
        self.assertEqual(code, EXIT_OK)
        self.assertIn("top-level-comment", out)
        self.assertIn("is itself a reply", out)
        self.assertEqual(transport.mutating_requests, [])

    def test_a_top_level_id_is_used_unchanged(self) -> None:
        transport = self._transport(owner=CHANNEL_ID)
        code, _, _ = self.run_cli(
            ["comments", "reply", "Ugx123", "--text-file", str(self.reply), "--apply"], transport
        )
        self.assertEqual(code, EXIT_OK)
        posted = transport.mutating_requests[0].json_body()
        self.assertEqual(posted["snippet"]["parentId"], "Ugx123")

    def test_a_missing_comment_is_reported_clearly(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route("GET", "/comments", payload={"items": []})
        code, _, err = self.run_cli(
            ["comments", "reply", "Ugx404", "--text-file", str(self.reply)], transport
        )
        self.assertNotEqual(code, EXIT_OK)
        self.assertIn("no comment found", err)


class CapabilityGuardTests(CliTestCase):
    def test_a_token_without_recorded_capabilities_grants_none(self) -> None:
        """Fail closed: an older or hand-edited token must not bypass the interlock."""
        storage.write_secret_json(
            storage.token_path(),
            {
                "refresh_token": "1//04-legacy",
                "access_token": "ya29.legacy",
                "expires_at": time.time() + 3600,
                "scopes": [oauth.SCOPE_YOUTUBE_READONLY, oauth.SCOPE_YOUTUBE_FORCE_SSL],
            },
        )
        reply = Path(self.temporary.name) / "reply.txt"
        reply.write_text("text\n", encoding="utf-8")

        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route(
            "GET",
            "/comments",
            payload={"items": [{"id": "Ugx1", "snippet": {"videoId": "v", "channelId": CHANNEL_ID}}]},
        )
        transport.route("GET", "/videos", payload={"items": [{"id": "v", "snippet": {"channelId": CHANNEL_ID}}]})
        transport.route("POST", "/comments", payload={"id": "should-not-happen"})

        code, _, err = self.run_cli(
            ["comments", "reply", "Ugx1", "--text-file", str(reply), "--apply"], transport
        )
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("recorded: none", err)
        self.assertEqual(transport.mutating_requests, [])

    def test_comments_read_also_fails_closed(self) -> None:
        storage.write_secret_json(
            storage.token_path(),
            {
                "refresh_token": "1//04-legacy",
                "access_token": "ya29.legacy",
                "expires_at": time.time() + 3600,
                "scopes": [oauth.SCOPE_YOUTUBE_READONLY, oauth.SCOPE_YOUTUBE_FORCE_SSL],
            },
        )
        code, _, err = self.run_cli(["comments", "list"], FakeTransport())
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("recorded: none", err)


class LoginPersistenceTests(CliTestCase):
    """A login for the wrong channel must leave nothing usable behind."""

    def _run_login(self, transport: FakeTransport, channel_payload: dict) -> tuple[int, str, str]:
        request = oauth.LoginRequest(
            authorisation_url="https://accounts.google.com/o/oauth2/v2/auth?client_id=x",
            redirect_uri="http://127.0.0.1:9999",
            state="state",
            code_verifier="verifier",
            scopes=oauth.READ_ONLY_SCOPES,
            server=None,
        )
        transport.route(
            "POST",
            "oauth2.googleapis.com/token",
            payload={
                "access_token": "ya29.new-token",
                "refresh_token": "1//04-new-refresh",
                "expires_in": 3600,
                "scope": " ".join(oauth.READ_ONLY_SCOPES),
            },
        )
        transport.route("GET", "mine=true", payload=channel_payload)
        transport.route("POST", "oauth2.googleapis.com/revoke", payload={})

        with mock.patch.object(oauth, "start_login", return_value=request), mock.patch.object(
            oauth, "await_authorisation_code", return_value="auth-code"
        ):
            return self.run_cli(["auth", "login", "--no-browser"], transport)

    def test_a_wrong_channel_login_stores_no_token(self) -> None:
        storage.remove(storage.token_path())
        transport = FakeTransport()
        code, _, err = self._run_login(
            transport, channel_resource(channel_id=OTHER_CHANNEL_ID, title="jonattree")
        )

        self.assertEqual(code, EXIT_CHANNEL_MISMATCH)
        self.assertFalse(storage.token_path().exists(), "a rejected grant must not be persisted")
        self.assertIn(OTHER_CHANNEL_ID, err)

    def test_a_wrong_channel_login_revokes_the_new_grant(self) -> None:
        storage.remove(storage.token_path())
        transport = FakeTransport()
        self._run_login(transport, channel_resource(channel_id=OTHER_CHANNEL_ID))

        revocations = transport.calls_to("revoke")
        self.assertEqual(len(revocations), 1, "the unwanted authorisation must be withdrawn")
        self.assertIn(b"token=", revocations[0].body or b"")

    def test_a_correct_login_stores_the_token_at_0600(self) -> None:
        storage.remove(storage.token_path())
        transport = FakeTransport()
        code, out, _ = self._run_login(transport, channel_resource())

        self.assertEqual(code, EXIT_OK)
        self.assertTrue(storage.token_path().exists())
        self.assertEqual(storage.permissions(storage.token_path()), 0o600)
        self.assertIn(CHANNEL_ID, out)
        self.assertEqual(transport.calls_to("revoke"), [], "a good login revokes nothing")


class AuthCommandTests(CliTestCase):
    def test_auth_status_lists_scopes_without_disclosing_tokens(self) -> None:
        code, out, _ = self.run_cli(["auth", "status"], FakeTransport())
        self.assertEqual(code, EXIT_OK)
        self.assertIn(oauth.SCOPE_YOUTUBE_READONLY, out)
        self.assertNotIn("1//04-test-refresh-token-value", out)
        self.assertNotIn("ya29.test-access-token-value", out)
        self.assertNotIn("GOCSPX-test-client-secret-value", out)
        self.assertIn("none (read-only)", out)

    def test_auth_status_without_a_token_exits_non_zero(self) -> None:
        storage.remove(storage.token_path())
        code, out, _ = self.run_cli(["auth", "status"], FakeTransport())
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("auth login", out)

    def test_auth_revoke_calls_google_and_clears_local_state(self) -> None:
        transport = FakeTransport().route("POST", "oauth2.googleapis.com/revoke", payload={})
        code, out, _ = self.run_cli(["auth", "revoke"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertFalse(storage.token_path().exists())
        self.assertIn("yes", out)
        body = transport.calls_to("revoke")[0].body or b""
        self.assertIn(b"token=", body, "the token is sent in the body, not the URL")
        self.assertNotIn("1//04-test-refresh-token-value", transport.calls_to("revoke")[0].url)

    def test_auth_revoke_removes_local_state_even_when_google_refuses(self) -> None:
        transport = FakeTransport().route(
            "POST", "revoke", status=400, payload={"error": "invalid_token"}
        )
        code, _, _ = self.run_cli(["auth", "revoke"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertFalse(storage.token_path().exists())

    def test_expired_authorisation_triggers_a_refresh(self) -> None:
        storage.write_secret_json(
            storage.token_path(),
            {
                "refresh_token": "1//04-test-refresh-token-value",
                "access_token": "ya29.expired",
                "expires_at": time.time() - 60,
                "scopes": list(oauth.READ_ONLY_SCOPES),
            },
        )
        transport = FakeTransport()
        transport.route(
            "POST",
            "oauth2.googleapis.com/token",
            payload={"access_token": "ya29.fresh-token", "expires_in": 3600, "token_type": "Bearer"},
        )
        transport.route("GET", "mine=true", payload=channel_resource())
        code, out, _ = self.run_cli(["status"], transport)
        self.assertEqual(code, EXIT_OK)
        self.assertEqual(len(transport.calls_to("oauth2.googleapis.com/token")), 1)
        self.assertNotIn("ya29.fresh-token", out)
        stored = storage.read_json(storage.token_path())
        self.assertEqual(stored["access_token"], "ya29.fresh-token")
        self.assertEqual(storage.permissions(storage.token_path()), 0o600)

    def test_a_revoked_refresh_token_asks_for_a_new_login(self) -> None:
        storage.write_secret_json(
            storage.token_path(),
            {
                "refresh_token": "1//04-revoked",
                "expires_at": time.time() - 60,
                "scopes": list(oauth.READ_ONLY_SCOPES),
            },
        )
        transport = FakeTransport().route(
            "POST",
            "oauth2.googleapis.com/token",
            status=400,
            payload={"error": "invalid_grant", "error_description": "Token has been expired or revoked."},
        )
        code, _, err = self.run_cli(["status"], transport)
        self.assertEqual(code, EXIT_AUTH_REQUIRED)
        self.assertIn("no longer valid", err)
        self.assertIn("auth login", err)

    def test_pkce_challenge_is_derived_with_s256(self) -> None:
        verifier = oauth.generate_code_verifier()
        self.assertGreaterEqual(len(verifier), 43)
        self.assertNotIn("=", verifier)
        challenge = oauth.derive_code_challenge(verifier)
        self.assertNotEqual(challenge, verifier)
        self.assertEqual(challenge, oauth.derive_code_challenge(verifier))

    def test_the_authorisation_url_carries_no_secret(self) -> None:
        url = oauth.build_authorisation_url(
            "123-test.apps.googleusercontent.com",
            "http://127.0.0.1:41234",
            oauth.READ_ONLY_SCOPES,
            "state-value",
            "challenge-value",
        )
        self.assertIn("code_challenge_method=S256", url)
        self.assertIn("access_type=offline", url)
        self.assertNotIn("client_secret", url)

    def test_login_scopes_are_read_only_unless_enabled(self) -> None:
        self.assertEqual(oauth.scopes_for([]), oauth.READ_ONLY_SCOPES)
        with_upload = oauth.scopes_for(["upload"])
        self.assertIn(oauth.SCOPE_YOUTUBE_UPLOAD, with_upload)
        self.assertNotIn(oauth.SCOPE_YOUTUBE_MANAGE, with_upload)
        self.assertNotIn(oauth.SCOPE_YOUTUBE_FORCE_SSL, with_upload)

    def test_every_capability_has_a_description_the_login_summary_can_print(self) -> None:
        for name in oauth.CAPABILITIES:
            scope, description = oauth.CAPABILITIES[name]
            self.assertTrue(scope.startswith("https://"), name)
            self.assertTrue(description, name)
        self.assertTrue(set(oauth.WRITE_CAPABILITIES) <= set(oauth.CAPABILITIES))

    def test_comments_read_is_not_counted_as_a_write_capability(self) -> None:
        self.assertIn("comments-read", oauth.CAPABILITIES)
        self.assertNotIn("comments-read", oauth.WRITE_CAPABILITIES)
        self.assertEqual(
            oauth.CAPABILITIES["comments-read"][0], oauth.CAPABILITIES["comment-reply"][0]
        )


class JsonOutputTests(CliTestCase):
    def test_json_mode_emits_one_parsable_document(self) -> None:
        transport = FakeTransport().route("GET", "mine=true", payload=channel_resource())
        code, out, _ = self.run_cli(["status", "--json"], transport)
        self.assertEqual(code, EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["channel"]["channel_id"], CHANNEL_ID)
        self.assertEqual(payload["pinned_channel"]["channel_id"], CHANNEL_ID)

    def test_json_status_never_contains_token_material(self) -> None:
        transport = FakeTransport().route("GET", "mine=true", payload=channel_resource())
        _, out, _ = self.run_cli(["status", "--json"], transport)
        for secret in (
            "1//04-test-refresh-token-value",
            "ya29.test-access-token-value",
            "GOCSPX-test-client-secret-value",
        ):
            self.assertNotIn(secret, out)

    def test_json_dry_run_is_marked_as_such(self) -> None:
        description = Path(self.temporary.name) / "description.txt"
        description.write_text("New description\n", encoding="utf-8")
        transport = FakeTransport()
        transport.route("GET", "mine=true", payload=channel_resource())
        transport.route("GET", "brandingSettings", payload=branding_resource())
        code, out, _ = self.run_cli(
            ["channel", "set-description", "--file", str(description), "--json"], transport
        )
        self.assertEqual(code, EXIT_OK)
        payload = json.loads(out)
        self.assertTrue(payload["dry_run"])
        self.assertFalse(payload["applied"])
        self.assertEqual(transport.mutating_requests, [])


if __name__ == "__main__":
    unittest.main()
