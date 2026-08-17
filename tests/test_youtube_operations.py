"""Mutation planning: read-modify-write preservation and the upload policy."""

from __future__ import annotations

import struct
import tempfile
import unittest
import zlib
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

VIDEO_SNIPPET = {
    "channelId": "UC123",
    "title": "Old title",
    "description": "Old description",
    "categoryId": "28",
    "tags": ["NextTang", "FPGA"],
    "defaultLanguage": "en-GB",
    "defaultAudioLanguage": "en-GB",
    "publishedAt": "2026-08-17T00:00:00Z",
    "thumbnails": {"default": {"url": "https://example.invalid/thumbnail.jpg"}},
}


def write_png(path: Path, width: int, height: int) -> None:
    """Write a tiny valid RGBA PNG without adding an image-library dependency."""
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    rows = b"".join(b"\x00" + b"\x00\x00\x00\x00" * width for _ in range(height))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, level=9))
        + chunk(b"IEND", b"")
    )


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

    def test_video_metadata_merge_preserves_mutable_snippet_fields_only(self) -> None:
        merged = operations.merge_video_metadata(VIDEO_SNIPPET, "New title", "New description")
        self.assertEqual(merged["title"], "New title")
        self.assertEqual(merged["description"], "New description")
        self.assertEqual(merged["categoryId"], "28")
        self.assertEqual(merged["tags"], ["NextTang", "FPGA"])
        self.assertEqual(merged["defaultLanguage"], "en-GB")
        self.assertEqual(merged["defaultAudioLanguage"], "en-GB")
        self.assertNotIn("channelId", merged)
        self.assertNotIn("publishedAt", merged)
        self.assertNotIn("thumbnails", merged)

    def test_video_metadata_merge_does_not_mutate_the_source(self) -> None:
        operations.merge_video_metadata(VIDEO_SNIPPET, "New title", "New description")
        self.assertEqual(VIDEO_SNIPPET["title"], "Old title")
        self.assertEqual(VIDEO_SNIPPET["description"], "Old description")

    def test_video_metadata_plan_shows_both_diffs_and_preservation(self) -> None:
        plan = operations.plan_video_metadata(
            "UC123", "vid123", VIDEO_SNIPPET, "New title", "New description"
        )
        self.assertEqual(plan.operation, "videos.update-metadata")
        self.assertIn("-Old title", plan.diff)
        self.assertIn("+New title", plan.diff)
        self.assertIn("-Old description", plan.diff)
        self.assertIn("+New description", plan.diff)
        self.assertTrue(any("categoryId" in note and "tags" in note for note in plan.notes))
        self.assertEqual(plan.payload["snippet"]["categoryId"], "28")

    def test_video_metadata_plan_refuses_no_change(self) -> None:
        with self.assertRaises(UsageError) as raised:
            operations.plan_video_metadata(
                "UC123", "vid123", VIDEO_SNIPPET, "Old title", "Old description"
            )
        self.assertIn("identical", raised.exception.message)

    def test_video_metadata_plan_requires_category(self) -> None:
        snippet = dict(VIDEO_SNIPPET)
        snippet.pop("categoryId")
        with self.assertRaises(UsageError) as raised:
            operations.plan_video_metadata(
                "UC123", "vid123", snippet, "New title", "New description"
            )
        self.assertIn("categoryId", raised.exception.message)

    def test_video_metadata_limits_are_enforced(self) -> None:
        with self.assertRaises(UsageError):
            operations.plan_video_metadata(
                "UC123", "vid123", VIDEO_SNIPPET, "x" * 101, "New description"
            )
        with self.assertRaises(UsageError):
            operations.plan_video_metadata(
                "UC123", "vid123", VIDEO_SNIPPET, "New title", "x" * 5001
            )

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

    def test_banner_merge_preserves_every_other_branding_field(self) -> None:
        merged = operations.merge_channel_banner(BRANDING, "https://example.invalid/new-banner")
        self.assertEqual(
            merged["image"]["bannerExternalUrl"], "https://example.invalid/new-banner"
        )
        self.assertEqual(merged["channel"], BRANDING["channel"])
        self.assertEqual(BRANDING["image"]["bannerExternalUrl"], "https://example.invalid/banner")


class ChannelArtworkPlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.banner = root / "banner.png"
        write_png(self.banner, 2048, 1152)
        self.watermark = root / "watermark.png"
        write_png(self.watermark, 150, 150)
        self.thumbnail = root / "thumbnail.png"
        write_png(self.thumbnail, 1280, 720)

    def test_banner_plan_accepts_the_documented_minimum(self) -> None:
        plan = operations.plan_channel_banner("UC123", BRANDING, self.banner)
        self.assertEqual(plan.operation, "channel.set-banner")
        self.assertEqual(plan.payload["mime_type"], "image/png")
        self.assertTrue(any("2048x1152" in note for note in plan.notes))
        self.assertTrue(any("two API writes" in note for note in plan.notes))

    def test_banner_rejects_wrong_aspect_ratio(self) -> None:
        write_png(self.banner, 2048, 1200)
        with self.assertRaises(UsageError) as raised:
            operations.plan_channel_banner("UC123", BRANDING, self.banner)
        self.assertIn("16:9", raised.exception.message)

    def test_banner_rejects_dimensions_below_minimum(self) -> None:
        write_png(self.banner, 1920, 1080)
        with self.assertRaises(UsageError) as raised:
            operations.plan_channel_banner("UC123", BRANDING, self.banner)
        self.assertIn("2048x1152", raised.exception.message)

    def test_extension_does_not_override_invalid_image_bytes(self) -> None:
        self.banner.write_bytes(b"not really a PNG")
        with self.assertRaises(UsageError) as raised:
            operations.plan_channel_banner("UC123", BRANDING, self.banner)
        self.assertIn("PNG or JPEG", raised.exception.message)

    def test_jpeg_dimensions_are_read_from_the_file(self) -> None:
        jpeg = self.banner.with_suffix(".jpg")
        jpeg.write_bytes(
            b"\xff\xd8"
            + b"\xff\xc0\x00\x0b"
            + b"\x08\x04\x80\x08\x00\x03\x01\x11\x00"
            + b"\xff\xd9"
        )
        plan = operations.plan_channel_banner("UC123", BRANDING, jpeg)
        self.assertEqual(plan.payload["mime_type"], "image/jpeg")

    def test_banner_size_limit_is_enforced_before_reading_the_file(self) -> None:
        with self.banner.open("r+b") as handle:
            handle.truncate(6 * 1024 * 1024 + 1)
        with self.assertRaises(UsageError) as raised:
            operations.plan_channel_banner("UC123", BRANDING, self.banner)
        self.assertIn("6 MiB", raised.exception.message)

    def test_watermark_plan_accepts_the_channel_asset(self) -> None:
        plan = operations.plan_channel_watermark("UC123", self.watermark)
        self.assertEqual(plan.operation, "channel.set-watermark")
        self.assertEqual(plan.payload["mime_type"], "image/png")
        self.assertEqual(plan.payload["timing"]["offsetMs"], 0)
        self.assertTrue(any("no read-back endpoint" in note for note in plan.notes))

    def test_watermark_requires_a_150_pixel_square(self) -> None:
        write_png(self.watermark, 200, 150)
        with self.assertRaises(UsageError) as raised:
            operations.plan_channel_watermark("UC123", self.watermark)
        self.assertIn("150x150", raised.exception.message)

    def test_thumbnail_plan_accepts_a_high_resolution_16_by_9_image(self) -> None:
        plan = operations.plan_video_thumbnail("UC123", "vid123", self.thumbnail)
        self.assertEqual(plan.operation, "videos.set-thumbnail")
        self.assertEqual(plan.payload["mime_type"], "image/png")
        self.assertEqual(plan.payload["video_id"], "vid123")
        self.assertEqual(plan.request["quota_units"], 50)

    def test_thumbnail_rejects_wrong_aspect_ratio(self) -> None:
        write_png(self.thumbnail, 1280, 800)
        with self.assertRaises(UsageError) as raised:
            operations.plan_video_thumbnail("UC123", "vid123", self.thumbnail)
        self.assertIn("16:9", raised.exception.message)

    def test_thumbnail_rejects_the_api_size_limit(self) -> None:
        with self.thumbnail.open("r+b") as handle:
            handle.truncate(2 * 1024 * 1024 + 1)
        with self.assertRaises(UsageError) as raised:
            operations.plan_video_thumbnail("UC123", "vid123", self.thumbnail)
        self.assertIn("2 MiB", raised.exception.message)


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
