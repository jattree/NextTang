"""Channel identity guard, bounded pagination, error mapping, comment triage."""

from __future__ import annotations

import unittest

from youtube_support import (
    CHANNEL_ID,
    OTHER_CHANNEL_ID,
    FakeTransport,
    branding_resource,
    channel_resource,
    comment_thread,
    error_payload,
)

from nexttang_youtube import channel as channel_module, comments
from nexttang_youtube.api import DEFAULT_LIMIT, MAX_LIMIT, YouTubeApi, validate_limit
from nexttang_youtube.channel import ChannelIdentity
from nexttang_youtube.errors import ApiError, AuthorisationError, ChannelMismatchError, QuotaError, ScopeError


def build_api(transport: FakeTransport) -> YouTubeApi:
    return YouTubeApi(transport, lambda: "test-access-token")


class ChannelGuardTests(unittest.TestCase):
    def test_pinned_channel_is_accepted(self) -> None:
        identity = ChannelIdentity(channel_id=CHANNEL_ID, title="NextTang", handle="@nexttangfpga")
        self.assertEqual(channel_module.verify(identity), [])

    def test_handle_case_difference_is_not_a_mismatch(self) -> None:
        identity = ChannelIdentity(channel_id=CHANNEL_ID, title="NextTang", handle="@NextTangFPGA")
        self.assertEqual(channel_module.verify(identity), [])

    def test_a_different_channel_is_refused(self) -> None:
        identity = ChannelIdentity(channel_id=OTHER_CHANNEL_ID, title="jonattree")
        with self.assertRaises(ChannelMismatchError) as raised:
            channel_module.verify(identity)
        self.assertEqual(raised.exception.observed, OTHER_CHANNEL_ID)
        self.assertEqual(raised.exception.expected, CHANNEL_ID)
        self.assertIn(OTHER_CHANNEL_ID, raised.exception.message)

    def test_empty_channel_id_is_refused(self) -> None:
        with self.assertRaises(ChannelMismatchError):
            channel_module.verify(ChannelIdentity(channel_id=""))

    def test_mutable_field_drift_warns_but_does_not_refuse(self) -> None:
        identity = ChannelIdentity(channel_id=CHANNEL_ID, title="NextTang FPGA", handle="@nexttang")
        warnings = channel_module.verify(identity)
        self.assertEqual(len(warnings), 2)
        self.assertTrue(all("pinned channel ID still matches" in warning for warning in warnings))

    def test_my_channel_resolves_through_the_api(self) -> None:
        transport = FakeTransport().route("GET", "/channels", payload=channel_resource())
        identity = build_api(transport).my_channel()
        self.assertEqual(identity.channel_id, CHANNEL_ID)
        self.assertEqual(identity.uploads_playlist_id, "UUzUSXeiPI3JMhlE5rmES4zA")
        self.assertIn("mine=true", transport.requests[0].url)

    def test_account_without_a_channel_is_an_authorisation_error(self) -> None:
        transport = FakeTransport().route("GET", "/channels", payload={"items": []})
        with self.assertRaises(AuthorisationError):
            build_api(transport).my_channel()

    def test_multiple_channels_are_refused_rather_than_guessed(self) -> None:
        payload = channel_resource()
        payload["items"].append(dict(payload["items"][0], id=OTHER_CHANNEL_ID))
        transport = FakeTransport().route("GET", "/channels", payload=payload)
        with self.assertRaises(ApiError):
            build_api(transport).my_channel()


class PaginationTests(unittest.TestCase):
    def _page(self, count: int, *, token: str | None, offset: int = 0) -> dict:
        payload = {
            "items": [
                {
                    "snippet": {"title": f"video {offset + index}", "position": offset + index},
                    "contentDetails": {"videoId": f"vid{offset + index:03d}"},
                }
                for index in range(count)
            ]
        }
        if token:
            payload["nextPageToken"] = token
        return payload

    def test_default_limit_is_twenty_five(self) -> None:
        transport = FakeTransport().route("GET", "playlistItems", payload=self._page(25, token=None))
        videos = build_api(transport).list_uploads("UU123", limit=DEFAULT_LIMIT)
        self.assertEqual(len(videos), 25)
        self.assertEqual(transport.query_values("playlistItems", "maxResults"), ["25"])

    def test_results_never_exceed_the_requested_limit(self) -> None:
        transport = FakeTransport().route("GET", "playlistItems", payload=self._page(50, token="next"))
        videos = build_api(transport).list_uploads("UU123", limit=10)
        self.assertEqual(len(videos), 10)

    def test_pagination_stops_when_the_limit_is_reached(self) -> None:
        transport = FakeTransport()
        transport.route("GET", "playlistItems", payload=self._page(50, token="page2"), times=1)
        transport.route("GET", "playlistItems", payload=self._page(50, token="page3", offset=50), times=1)
        videos = build_api(transport).list_uploads("UU123", limit=75)

        self.assertEqual(len(videos), 75)
        self.assertEqual(len(transport.calls_to("playlistItems")), 2)
        self.assertEqual(transport.query_values("playlistItems", "maxResults"), ["50", "25"])
        self.assertEqual(transport.query_values("playlistItems", "pageToken"), ["page2"])

    def test_page_size_is_capped_below_the_limit(self) -> None:
        transport = FakeTransport()
        for index in range(4):
            transport.route(
                "GET", "playlistItems", payload=self._page(50, token=f"p{index}", offset=index * 50), times=1
            )
        videos = build_api(transport).list_uploads("UU123", limit=200)
        self.assertEqual(len(videos), 200)
        self.assertEqual(transport.query_values("playlistItems", "maxResults"), ["50", "50", "50", "50"])

    def test_a_short_page_without_a_token_ends_the_sweep(self) -> None:
        transport = FakeTransport().route("GET", "playlistItems", payload=self._page(3, token=None))
        videos = build_api(transport).list_uploads("UU123", limit=200)
        self.assertEqual(len(videos), 3)
        self.assertEqual(len(transport.calls_to("playlistItems")), 1)

    def test_limits_outside_the_bounds_are_refused(self) -> None:
        self.assertEqual(validate_limit(1), 1)
        self.assertEqual(validate_limit(MAX_LIMIT), MAX_LIMIT)
        with self.assertRaises(ApiError):
            validate_limit(0)
        with self.assertRaises(ApiError):
            validate_limit(MAX_LIMIT + 1)

    def test_video_details_are_batched(self) -> None:
        ids = [f"vid{index:03d}" for index in range(60)]
        transport = FakeTransport()
        transport.route("GET", "/videos", payload={"items": [{"id": value, "status": {"privacyStatus": "public"}} for value in ids[:50]]}, times=1)
        transport.route("GET", "/videos", payload={"items": [{"id": value, "status": {"privacyStatus": "private"}} for value in ids[50:]]}, times=1)
        details = build_api(transport).video_details(ids)
        self.assertEqual(len(details), 60)
        self.assertEqual(len(transport.calls_to("/videos")), 2)
        self.assertEqual(details["vid059"]["privacy_status"], "private")


class ErrorMappingTests(unittest.TestCase):
    def test_expired_authorisation_maps_to_an_auth_error(self) -> None:
        transport = FakeTransport().route(
            "GET", "/channels", status=401, payload=error_payload(401, "authError", "Invalid Credentials")
        )
        with self.assertRaises(AuthorisationError) as raised:
            build_api(transport).my_channel()
        self.assertIn("auth login", raised.exception.hint or "")

    def test_quota_exhaustion_maps_to_a_quota_error(self) -> None:
        transport = FakeTransport().route(
            "GET", "/channels", status=403, payload=error_payload(403, "quotaExceeded", "quota exceeded")
        )
        with self.assertRaises(QuotaError) as raised:
            build_api(transport).my_channel()
        self.assertIn("Pacific", raised.exception.hint or "")

    def test_rate_limiting_maps_to_a_quota_error(self) -> None:
        transport = FakeTransport().route(
            "GET", "/channels", status=429, payload=error_payload(429, "rateLimitExceeded")
        )
        with self.assertRaises(QuotaError):
            build_api(transport).my_channel()

    def test_missing_scope_maps_to_a_scope_error(self) -> None:
        transport = FakeTransport().route(
            "PUT",
            "/channels",
            status=403,
            payload=error_payload(403, "insufficientPermissions", "insufficient scope"),
        )
        with self.assertRaises(ScopeError):
            build_api(transport).update_channel_branding(CHANNEL_ID, {"channel": {}})

    def test_other_failures_carry_the_status(self) -> None:
        transport = FakeTransport().route(
            "GET", "/channels", status=404, payload=error_payload(404, "notFound", "missing")
        )
        with self.assertRaises(ApiError) as raised:
            build_api(transport).my_channel()
        self.assertEqual(raised.exception.status, 404)

    def test_error_bodies_are_redacted_before_being_reported(self) -> None:
        transport = FakeTransport().route(
            "GET",
            "/channels",
            status=400,
            payload={
                "error": {
                    "code": 400,
                    "message": 'failed for access_token: "ya29.LEAKED-TOKEN-VALUE"',
                    "errors": [{"reason": "badRequest"}],
                }
            },
        )
        with self.assertRaises(ApiError) as raised:
            build_api(transport).my_channel()
        self.assertNotIn("ya29.LEAKED-TOKEN-VALUE", raised.exception.message)

    def test_branding_read_returns_the_part(self) -> None:
        transport = FakeTransport().route("GET", "/channels", payload=branding_resource())
        branding = build_api(transport).channel_branding(CHANNEL_ID)
        self.assertEqual(branding["channel"]["description"], "Original description")


class CommentClassificationTests(unittest.TestCase):
    def test_a_thread_with_no_replies_is_unanswered(self) -> None:
        result = comments.classify_thread(comment_thread("t1"), CHANNEL_ID)
        self.assertEqual(result.state, comments.UNANSWERED)
        self.assertTrue(result.reply_data_complete)
        self.assertTrue(result.needs_attention)

    def test_a_channel_reply_marks_the_thread_answered(self) -> None:
        thread = comment_thread("t2", total_replies=1, reply_authors=(CHANNEL_ID,))
        result = comments.classify_thread(thread, CHANNEL_ID)
        self.assertEqual(result.state, comments.ANSWERED)
        self.assertFalse(result.needs_attention)

    def test_replies_from_other_viewers_leave_it_unanswered(self) -> None:
        thread = comment_thread("t3", total_replies=2, reply_authors=("UCother1", "UCother2"))
        result = comments.classify_thread(thread, CHANNEL_ID)
        self.assertEqual(result.state, comments.UNANSWERED)
        self.assertTrue(result.reply_data_complete)

    def test_truncated_reply_data_is_reported_as_uncertain(self) -> None:
        thread = comment_thread("t4", total_replies=9, reply_authors=("UCother1", "UCother2"))
        result = comments.classify_thread(thread, CHANNEL_ID)
        self.assertEqual(result.state, comments.UNCERTAIN)
        self.assertFalse(result.reply_data_complete)
        self.assertTrue(result.needs_attention)
        self.assertIn("2 of 9", result.reason)

    def test_the_channels_own_comment_is_not_something_to_answer(self) -> None:
        thread = comment_thread("t5", author_channel_id=CHANNEL_ID)
        result = comments.classify_thread(thread, CHANNEL_ID)
        self.assertEqual(result.state, comments.OWN_COMMENT)
        self.assertFalse(result.needs_attention)

    def test_selection_includes_uncertain_by_default(self) -> None:
        threads = [
            comment_thread("t1"),
            comment_thread("t2", total_replies=1, reply_authors=(CHANNEL_ID,)),
            comment_thread("t3", total_replies=9, reply_authors=("UCother",)),
            comment_thread("t4", author_channel_id=CHANNEL_ID),
        ]
        selected = comments.select_unanswered(threads, CHANNEL_ID)
        self.assertEqual([record["thread_id"] for record in selected], ["t1", "t3"])

        strict = comments.select_unanswered(threads, CHANNEL_ID, include_uncertain=False)
        self.assertEqual([record["thread_id"] for record in strict], ["t1"])

    def test_summary_carries_the_reply_target(self) -> None:
        thread = comment_thread("t6", text="Does this run on a 60K?")
        record = comments.summarise_thread(thread, comments.classify_thread(thread, CHANNEL_ID))
        self.assertEqual(record["comment_id"], "t6-top")
        self.assertEqual(record["text"], "Does this run on a 60K?")
        self.assertEqual(record["video_id"], "video123")


if __name__ == "__main__":
    unittest.main()
