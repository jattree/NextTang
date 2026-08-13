"""Credential storage permissions, atomicity, and secret redaction."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import youtube_support  # noqa: F401 - puts the CLI package on sys.path

from nexttang_youtube import redaction, storage


class StorageDirectoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "config"
        patcher = mock.patch.dict(os.environ, {storage.CONFIG_DIR_ENV: str(self.root)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.temporary.cleanup)

    def test_config_directory_is_created_private(self) -> None:
        directory = storage.ensure_config_dir()
        self.assertEqual(directory, self.root)
        self.assertEqual(storage.permissions(directory), 0o700)

    def test_loose_directory_permissions_are_repaired(self) -> None:
        self.root.mkdir(parents=True)
        self.root.chmod(0o755)
        storage.ensure_config_dir()
        self.assertEqual(storage.permissions(self.root), 0o700)

    def test_secret_file_is_written_at_0600(self) -> None:
        target = storage.token_path()
        storage.write_secret_json(target, {"refresh_token": "value"})
        self.assertEqual(storage.permissions(target), 0o600)
        self.assertEqual(storage.permissions(target.parent), 0o700)
        self.assertEqual(storage.read_json(target), {"refresh_token": "value"})

    def test_write_replaces_content_without_leaving_temporary_files(self) -> None:
        target = storage.token_path()
        storage.write_secret_json(target, {"generation": 1})
        storage.write_secret_json(target, {"generation": 2})
        self.assertEqual(storage.read_json(target), {"generation": 2})
        leftovers = [item.name for item in target.parent.iterdir() if item.name != target.name]
        self.assertEqual(leftovers, [])

    def test_failed_write_leaves_the_previous_state_intact(self) -> None:
        target = storage.token_path()
        storage.write_secret_json(target, {"refresh_token": "original"})

        class Unserialisable:
            pass

        with self.assertRaises(TypeError):
            storage.write_secret_json(target, {"refresh_token": Unserialisable()})

        self.assertEqual(storage.read_json(target), {"refresh_token": "original"})
        self.assertEqual(storage.permissions(target), 0o600)
        leftovers = [item.name for item in target.parent.iterdir() if item.name != target.name]
        self.assertEqual(leftovers, [], "an interrupted write must not leave a temporary file")

    def test_describe_permissions_reports_absent_files(self) -> None:
        self.assertEqual(storage.describe_permissions(storage.token_path()), "absent")

    def test_remove_reports_whether_anything_was_deleted(self) -> None:
        target = storage.token_path()
        self.assertFalse(storage.remove(target))
        storage.write_secret_json(target, {"a": 1})
        self.assertTrue(storage.remove(target))
        self.assertFalse(target.exists())


class RedactionTests(unittest.TestCase):
    def setUp(self) -> None:
        redaction.forget_secrets()
        self.addCleanup(redaction.forget_secrets)

    def test_json_token_fields_are_masked(self) -> None:
        body = json.dumps(
            {
                "access_token": "ya29.a0AfH6SMB-real-looking-token",
                "refresh_token": "1//04-refresh-token-value",
                "expires_in": 3599,
            }
        )
        result = redaction.redact(body)
        self.assertNotIn("ya29.a0AfH6SMB-real-looking-token", result)
        self.assertNotIn("1//04-refresh-token-value", result)
        self.assertIn(redaction.PLACEHOLDER, result)
        self.assertIn("3599", result, "non-secret fields must survive")

    def test_query_parameters_are_masked(self) -> None:
        url = "https://oauth2.googleapis.com/revoke?token=1//04-refresh-token-value&other=keep"
        result = redaction.redact_url(url)
        self.assertNotIn("1//04-refresh-token-value", result)
        self.assertIn("other=keep", result)

    def test_authorization_headers_are_masked(self) -> None:
        text = "Authorization: Bearer ya29.SOME-ACCESS-TOKEN"
        self.assertNotIn("ya29.SOME-ACCESS-TOKEN", redaction.redact(text))

    def test_registered_secret_is_masked_anywhere(self) -> None:
        redaction.register_secret("GOCSPX-client-secret-value")
        message = "the tool said GOCSPX-client-secret-value in an unexpected place"
        self.assertNotIn("GOCSPX-client-secret-value", redaction.redact(message))

    def test_short_values_are_not_registered(self) -> None:
        redaction.register_secret("abc")
        self.assertIn("abc", redaction.redact("abc appears in ordinary text"))

    def test_error_codes_are_not_mistaken_for_secrets(self) -> None:
        body = json.dumps({"error": {"code": 403, "message": "quota"}})
        self.assertIn("403", redaction.redact(body))

    def test_summarise_secret_never_discloses(self) -> None:
        described = redaction.summarise_secret("GOCSPX-client-secret-value")
        self.assertNotIn("GOCSPX", described)
        self.assertIn("present", described)
        self.assertEqual(redaction.summarise_secret(None), "absent")


if __name__ == "__main__":
    unittest.main()
