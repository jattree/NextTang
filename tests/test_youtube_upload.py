"""Resumable upload behaviour: headers, streaming, retries, and bounds.

These cover the failure paths that a dry run can never reach, so the uploader is
not trusted purely on the strength of its happy path.

Protocol reference:
https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
"""

from __future__ import annotations

import http.client
import json
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

from youtube_support import FakeTransport, error_payload

from nexttang_youtube.api import MAX_UPLOAD_ATTEMPTS, YouTubeApi
from nexttang_youtube.errors import ApiError, AuthorisationError
from nexttang_youtube.transport import UrllibTransport

SESSION = "https://www.googleapis.com/upload/session/abc"


class UploadTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.slept: list[float] = []
        self.now = 0.0

    def make_file(self, size: int) -> Path:
        path = Path(self.temporary.name) / "video.mp4"
        path.write_bytes(bytes(index % 251 for index in range(size)))
        return path

    def api(self, transport: FakeTransport) -> YouTubeApi:
        return YouTubeApi(transport, lambda: "test-access-token")

    def sleeper(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds

    def clock(self) -> float:
        self.now += 0.001
        return self.now


class TransportFailureTests(unittest.TestCase):
    def test_network_failure_does_not_claim_remote_state_is_unchanged(self) -> None:
        with mock.patch(
            "nexttang_youtube.transport.urllib.request.urlopen",
            side_effect=urllib.error.URLError("connection reset"),
        ):
            with self.assertRaises(ApiError) as raised:
                UrllibTransport().request("PUT", SESSION, body=b"video bytes")

        hint = raised.exception.hint or ""
        self.assertNotIn("No API state changed", hint)
        self.assertIn("remote result may be unknown", hint)


class ChunkTransmissionTests(UploadTestCase):
    def test_every_chunk_carries_authorisation_and_content_type(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport().route(
            "PUT", SESSION, payload={"id": "vid", "status": {"privacyStatus": "private"}}
        )
        self.api(transport).upload_file(SESSION, path, "video/mp4", chunk_size=1024)

        puts = transport.calls_to(SESSION)
        self.assertTrue(puts)
        for request in puts:
            self.assertEqual(request.headers.get("Authorization"), "Bearer test-access-token")
            self.assertEqual(request.headers.get("Content-Type"), "video/mp4")
            self.assertIn("Content-Range", request.headers)

    def test_a_large_file_is_sent_in_bounded_chunks(self) -> None:
        path = self.make_file(2500)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-999"}, times=1)
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-1999"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        result = self.api(transport).upload_file(SESSION, path, chunk_size=1000)

        self.assertEqual(result["id"], "vid")
        ranges = [request.headers["Content-Range"] for request in transport.calls_to(SESSION)]
        self.assertEqual(
            ranges,
            ["bytes 0-999/2500", "bytes 1000-1999/2500", "bytes 2000-2499/2500"],
        )
        sizes = [len(request.body or b"") for request in transport.calls_to(SESSION)]
        self.assertEqual(sizes, [1000, 1000, 500])
        self.assertTrue(
            all(size <= 1000 for size in sizes),
            "no request may carry more than one chunk, or the file is being held in memory",
        )

    def test_the_server_offset_overrides_the_local_one(self) -> None:
        """A 308 that acknowledges fewer bytes must rewind, not skip data."""
        path = self.make_file(3000)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-499"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        self.api(transport).upload_file(SESSION, path, chunk_size=1000)

        ranges = [request.headers["Content-Range"] for request in transport.calls_to(SESSION)]
        self.assertEqual(ranges, ["bytes 0-999/3000", "bytes 500-1499/3000"])

    def test_an_empty_file_is_refused_before_any_request(self) -> None:
        path = Path(self.temporary.name) / "empty.mp4"
        path.write_bytes(b"")
        transport = FakeTransport()
        with self.assertRaises(ApiError):
            self.api(transport).upload_file(SESSION, path)
        self.assertEqual(transport.requests, [])


class RetryTests(UploadTestCase):
    def test_a_transient_server_error_is_retried(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=503, payload=error_payload(503, "backendError"), times=1)
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-49"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )

        self.assertEqual(result["id"], "vid")
        self.assertEqual(len(self.slept), 1, "one failure means one backoff")
        self.assertGreater(self.slept[0], 0)

    def test_a_network_failure_is_retried(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, times=1, error="connection reset")
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-9"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )
        self.assertEqual(result["id"], "vid")

    def test_retries_are_capped(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=500, payload=error_payload(500, "backendError"))

        with self.assertRaises(ApiError) as raised:
            self.api(transport).upload_file(
                SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
            )

        self.assertIn("after", raised.exception.message)
        self.assertIn("attempts", raised.exception.message)
        self.assertEqual(len(self.slept), MAX_UPLOAD_ATTEMPTS - 1)

    def test_backoff_grows_and_stays_bounded(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=503, payload=error_payload(503, "backendError"))

        with self.assertRaises(ApiError):
            self.api(transport).upload_file(
                SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
            )

        self.assertEqual(self.slept, sorted(self.slept), "backoff must not shrink")
        self.assertTrue(all(delay <= 64.0 for delay in self.slept), "backoff must stay bounded")

    def test_the_overall_deadline_is_enforced(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=503, payload=error_payload(503, "backendError"))

        def impatient_sleeper(seconds: float) -> None:
            self.slept.append(seconds)
            self.now += 10_000.0

        with self.assertRaises(ApiError) as raised:
            self.api(transport).upload_file(
                SESSION,
                path,
                chunk_size=1000,
                deadline_seconds=60.0,
                clock=self.clock,
                sleeper=impatient_sleeper,
            )
        self.assertIn("deadline", raised.exception.message)

    def test_a_retry_asks_the_server_what_it_holds(self) -> None:
        path = self.make_file(2000)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=503, payload=error_payload(503, "backendError"), times=1)
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-1499"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )

        ranges = [request.headers["Content-Range"] for request in transport.calls_to(SESSION)]
        self.assertEqual(ranges[1], "bytes */2000", "the retry must query the committed offset")
        self.assertEqual(ranges[2], "bytes 1500-1999/2000", "and resume from what the server holds")

    def test_a_permanent_failure_is_not_retried(self) -> None:
        """404 means the upload session is gone. Retrying it wastes the deadline."""
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route(
            "PUT", SESSION, status=404, payload=error_payload(404, "notFound"), times=1
        )

        with self.assertRaises(ApiError):
            self.api(transport).upload_file(
                SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
            )
        self.assertEqual(self.slept, [], "a permanent refusal must fail fast")
        self.assertEqual(len(transport.calls_to(SESSION)), 1)

    def test_an_expired_token_surfaces_as_an_auth_error(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route(
            "PUT", SESSION, status=401, payload=error_payload(401, "authError"), times=1
        )

        with self.assertRaises(AuthorisationError):
            self.api(transport).upload_file(
                SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
            )


class CompletionRecoveryTests(UploadTestCase):
    """A finished upload must never be reported as a failure.

    Reporting failure for an upload that actually completed invites the operator
    to upload the same video twice.
    """

    def test_a_status_probe_returning_201_yields_the_video_resource(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, times=1, error="connection reset")
        transport.route(
            "PUT",
            SESSION,
            status=201,
            payload={"id": "REAL-VIDEO-ID", "status": {"privacyStatus": "private"}},
            times=1,
        )

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )

        self.assertEqual(result["id"], "REAL-VIDEO-ID")
        self.assertEqual(result["status"]["privacyStatus"], "private")

    def test_a_status_probe_returning_200_yields_the_video_resource(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=503, payload=error_payload(503, "backendError"), times=1)
        transport.route("PUT", SESSION, status=200, payload={"id": "VID-200"}, times=1)

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )
        self.assertEqual(result["id"], "VID-200")

    def test_malformed_completion_resource_is_recovered_with_a_status_probe(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=201, body=b'{"id":', times=1)
        transport.route("PUT", SESSION, status=201, payload={"id": "RECOVERED"}, times=1)

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )

        self.assertEqual(result["id"], "RECOVERED")
        self.assertEqual(
            transport.calls_to(SESSION)[-1].headers["Content-Range"],
            "bytes */100",
        )

    def test_empty_completion_resource_is_recovered_with_a_status_probe(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=201, body=b"", times=1)
        transport.route("PUT", SESSION, status=201, payload={"id": "RECOVERED"}, times=1)

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )

        self.assertEqual(result["id"], "RECOVERED")

    def test_completion_resource_without_a_video_id_is_recovered_with_a_status_probe(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route(
            "PUT",
            SESSION,
            status=201,
            payload={"status": {"privacyStatus": "private"}},
            times=1,
        )
        transport.route("PUT", SESSION, status=201, payload={"id": "RECOVERED"}, times=1)

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )

        self.assertEqual(result["id"], "RECOVERED")

    def test_interrupted_completion_body_is_normalized_and_recovered(self) -> None:
        class BrokenCompletion:
            status = 201
            headers: dict[str, str] = {}

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                raise http.client.IncompleteRead(b'{"id":', 20)

        class RecoveredCompletion:
            status = 201
            headers: dict[str, str] = {}

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return json.dumps({"id": "RECOVERED"}).encode("utf-8")

        path = self.make_file(100)
        api = YouTubeApi(UrllibTransport(), lambda: "test-access-token")
        with mock.patch(
            "nexttang_youtube.transport.urllib.request.urlopen",
            side_effect=[BrokenCompletion(), RecoveredCompletion()],
        ) as urlopen:
            result = api.upload_file(
                SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
            )

        self.assertEqual(result["id"], "RECOVERED")
        self.assertEqual(urlopen.call_count, 2, "the second request must probe upload status")

    def test_a_lost_final_response_is_recovered_before_declaring_failure(self) -> None:
        """Every byte is committed but the completing response never arrives."""
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-99"}, times=1)
        transport.route("PUT", SESSION, status=201, payload={"id": "RECOVERED"}, times=1)

        result = self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )

        self.assertEqual(result["id"], "RECOVERED")
        self.assertEqual(
            transport.calls_to(SESSION)[-1].headers["Content-Range"],
            "bytes */100",
            "the final check must be a status probe",
        )

    def test_the_retry_limit_probes_before_declaring_failure(self) -> None:
        """The last permitted request reaches Google, which commits, then the response is lost."""
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, times=1, error="connection reset")
        transport.route("PUT", SESSION, status=201, payload={"id": "COMMITTED-VIDEO"}, times=1)

        result = self.api(transport).upload_file(
            SESSION,
            path,
            chunk_size=1000,
            max_attempts=1,
            clock=self.clock,
            sleeper=self.sleeper,
        )

        self.assertEqual(result["id"], "COMMITTED-VIDEO")
        probes = [
            request
            for request in transport.calls_to(SESSION)
            if request.headers.get("Content-Range") == "bytes */100"
        ]
        self.assertEqual(len(probes), 1, "the retry limit must ask before giving up")

    def test_the_deadline_probes_before_declaring_failure(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=503, payload=error_payload(503, "backendError"), times=1)
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-49"}, times=1)
        transport.route("PUT", SESSION, status=201, payload={"id": "LATE-BUT-REAL"}, times=1)

        def impatient_sleeper(seconds: float) -> None:
            self.slept.append(seconds)
            self.now += 10_000.0

        result = self.api(transport).upload_file(
            SESSION,
            path,
            chunk_size=1000,
            deadline_seconds=60.0,
            clock=self.clock,
            sleeper=impatient_sleeper,
        )
        self.assertEqual(result["id"], "LATE-BUT-REAL")

    def test_no_failure_path_claims_that_nothing_was_published(self) -> None:
        """The tool cannot know that, so it must not say it."""
        path = self.make_file(100)
        for limit_kwargs in ({"max_attempts": 1}, {"deadline_seconds": 0.0}):
            with self.subTest(**limit_kwargs):
                transport = FakeTransport()
                transport.route("PUT", SESSION, times=1, error="connection reset")
                transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-49"})

                with self.assertRaises(ApiError) as raised:
                    self.api(transport).upload_file(
                        SESSION,
                        path,
                        chunk_size=1000,
                        clock=self.clock,
                        sleeper=self.sleeper,
                        **limit_kwargs,
                    )

                combined = f"{raised.exception.message} {raised.exception.hint or ''}"
                self.assertNotIn("Nothing was published", combined)
                self.assertIn("videos list", combined)
                self.assertIn("may", combined, "the wording must express uncertainty")

    def test_a_genuinely_incomplete_upload_still_fails(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-99"}, times=1)
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-49"}, times=1)

        with self.assertRaises(ApiError) as raised:
            self.api(transport).upload_file(
                SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
            )
        self.assertIn("no completion response", raised.exception.message)
        self.assertIn("videos list", raised.exception.hint or "")


class RetryAfterTests(UploadTestCase):
    def test_a_numeric_retry_after_is_honoured(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route(
            "PUT",
            SESSION,
            status=503,
            headers={"Retry-After": "7"},
            payload=error_payload(503, "backendError"),
            times=1,
        )
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-9"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )
        self.assertEqual(self.slept, [7.0])

    def test_a_http_date_retry_after_is_honoured(self) -> None:
        import email.utils
        import time as time_module

        when = email.utils.formatdate(time_module.time() + 30, usegmt=True)
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route(
            "PUT",
            SESSION,
            status=429,
            headers={"Retry-After": when},
            payload=error_payload(429, "rateLimitExceeded"),
            times=1,
        )
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-9"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )
        self.assertEqual(len(self.slept), 1)
        self.assertGreater(self.slept[0], 20.0)
        self.assertLessEqual(self.slept[0], 31.0)

    def test_an_excessive_retry_after_is_capped(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route(
            "PUT",
            SESSION,
            status=503,
            headers={"Retry-After": "86400"},
            payload=error_payload(503, "backendError"),
            times=1,
        )
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-9"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )
        self.assertEqual(self.slept, [64.0], "a day-long delay must be bounded")

    def test_an_unparsable_retry_after_falls_back_to_backoff(self) -> None:
        path = self.make_file(100)
        transport = FakeTransport()
        transport.route(
            "PUT",
            SESSION,
            status=503,
            headers={"Retry-After": "not-a-date"},
            payload=error_payload(503, "backendError"),
            times=1,
        )
        transport.route("PUT", SESSION, status=308, headers={"Range": "bytes=0-9"}, times=1)
        transport.route("PUT", SESSION, payload={"id": "vid"}, times=1)

        self.api(transport).upload_file(
            SESSION, path, chunk_size=1000, clock=self.clock, sleeper=self.sleeper
        )
        self.assertEqual(len(self.slept), 1)
        self.assertGreater(self.slept[0], 0.0)


class SessionTests(UploadTestCase):
    def test_the_session_request_declares_length_and_type(self) -> None:
        transport = FakeTransport().route(
            "POST", "/upload/youtube/v3/videos", headers={"Location": SESSION}, payload={}
        )
        url = self.api(transport).start_resumable_upload(
            {"snippet": {"title": "t"}, "status": {"privacyStatus": "private"}}, 4096, "video/mp4"
        )
        self.assertEqual(url, SESSION)
        request = transport.calls_to("/upload/youtube/v3/videos")[0]
        self.assertEqual(request.headers["X-Upload-Content-Length"], "4096")
        self.assertEqual(request.headers["X-Upload-Content-Type"], "video/mp4")
        self.assertIn("uploadType=resumable", request.url)

    def test_a_session_response_without_a_location_is_an_error(self) -> None:
        transport = FakeTransport().route("POST", "/upload/youtube/v3/videos", payload={})
        with self.assertRaises(ApiError):
            self.api(transport).start_resumable_upload({}, 10, "video/mp4")


if __name__ == "__main__":
    unittest.main()
