"""Mutation planning: read-modify-write preservation and the upload policy."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import youtube_support  # noqa: F401 - puts the CLI package on sys.path

from nexttang_youtube import operations
from nexttang_youtube.errors import UsageError

BRANDING = {
    "channel": {
        "title": "NextTang",
        "description": "Original description",
        "keywords": "fpga tang zxspectrumnext",
        "country": "GB",
        "defaultLanguage": "en",
        "unsubscribedTrailer": "abcdefghijk",
        "trackingAnalyticsAccountId": "UA-000000-0",
    },
    "image": {"bannerExternalUrl": "https://example.invalid/banner"},
}


class ReadModifyWriteTests(unittest.TestCase):
    def test_every_other_field_is_preserved(self) -> None:
        merged = operations.merge_channel_description(BRANDING, "New description")
        self.assertEqual(merged["channel"]["description"], "New description")
        for key, value in BRANDING["channel"].items():
            if key == "description":
                continue
            self.assertEqual(merged["channel"][key], value, f"{key} must survive the write")
        self.assertEqual(merged["image"], BRANDING["image"], "sibling sections must survive")

    def test_the_source_object_is_not_mutated(self) -> None:
        operations.merge_channel_description(BRANDING, "New description")
        self.assertEqual(BRANDING["channel"]["description"], "Original description")

    def test_an_empty_branding_block_still_produces_a_description(self) -> None:
        merged = operations.merge_channel_description({}, "New description")
        self.assertEqual(merged, {"channel": {"description": "New description"}})

    def test_plan_lists_the_preserved_fields(self) -> None:
        plan = operations.plan_channel_description("UC123", BRANDING, "New description")
        preserved = next(note for note in plan.notes if note.startswith("preserved brandingSettings.channel"))
        for key in ("country", "keywords", "title", "unsubscribedTrailer"):
            self.assertIn(key, preserved)
        self.assertIn("image", next(note for note in plan.notes if "sections" in note))

    def test_plan_payload_carries_the_complete_object(self) -> None:
        plan = operations.plan_channel_description("UC123", BRANDING, "New description")
        self.assertEqual(plan.payload["branding"]["channel"]["country"], "GB")
        self.assertEqual(plan.payload["channel_id"], "UC123")

    def test_plan_shows_a_diff(self) -> None:
        plan = operations.plan_channel_description("UC123", BRANDING, "New description")
        self.assertTrue(any(line.startswith("-Original description") for line in plan.diff))
        self.assertTrue(any(line.startswith("+New description") for line in plan.diff))

    def test_an_unchanged_description_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_channel_description("UC123", BRANDING, "Original description")

    def test_an_over_long_description_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_channel_description("UC123", BRANDING, "x" * 1001)

    def test_empty_branding_is_flagged_as_unsafe(self) -> None:
        plan = operations.plan_channel_description("UC123", {}, "New description")
        self.assertTrue(any("WARNING" in note for note in plan.notes))


class UploadPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.video = Path(self.temporary.name) / "devlog-001.mp4"
        self.video.write_bytes(b"\x00" * 2048)

    def test_private_is_accepted(self) -> None:
        plan = operations.plan_video_upload(self.video, "private")
        self.assertEqual(plan.payload["metadata"]["status"]["privacyStatus"], "private")
        self.assertEqual(plan.payload["metadata"]["snippet"]["title"], "devlog-001")

    def test_public_is_refused(self) -> None:
        with self.assertRaises(UsageError) as raised:
            operations.plan_video_upload(self.video, "public")
        self.assertIn("only as private", raised.exception.message)

    def test_unlisted_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_video_upload(self.video, "unlisted")

    def test_an_unknown_privacy_value_is_refused(self) -> None:
        with self.assertRaises(UsageError) as raised:
            operations.plan_video_upload(self.video, "secret")
        self.assertIn("unknown privacy value", raised.exception.message)

    def test_a_missing_file_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_video_upload(Path(self.temporary.name) / "absent.mp4", "private")

    def test_an_empty_file_is_refused(self) -> None:
        empty = Path(self.temporary.name) / "empty.mp4"
        empty.write_bytes(b"")
        with self.assertRaises(UsageError):
            operations.plan_video_upload(empty, "private")

    def test_the_unverified_project_restriction_is_stated(self) -> None:
        plan = operations.plan_video_upload(self.video, "private")
        self.assertTrue(any("unverified API project" in note for note in plan.notes))
        self.assertTrue(any("never publishes" in note for note in plan.notes))

    def test_the_plan_records_a_content_hash(self) -> None:
        plan = operations.plan_video_upload(self.video, "private")
        digest = operations.sha256_of(self.video)
        self.assertTrue(any(digest in note for note in plan.notes))

    def test_made_for_kids_is_not_declared_on_the_owners_behalf(self) -> None:
        plan = operations.plan_video_upload(self.video, "private")
        self.assertNotIn("selfDeclaredMadeForKids", plan.payload["metadata"]["status"])


class CommentReplyPlanTests(unittest.TestCase):
    def test_a_plan_previews_the_reply(self) -> None:
        plan = operations.plan_comment_reply("Ugx123", "Thanks, the 138K board is still in transit.")
        self.assertEqual(plan.payload["parent_id"], "Ugx123")
        self.assertTrue(any(line.startswith("+Thanks") for line in plan.diff))

    def test_an_empty_reply_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_comment_reply("Ugx123", "   \n  ")

    def test_a_missing_comment_id_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_comment_reply("  ", "text")

    def test_an_over_long_reply_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_comment_reply("Ugx123", "x" * 10001)


if __name__ == "__main__":
    unittest.main()
