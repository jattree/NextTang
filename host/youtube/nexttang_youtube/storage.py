"""Local credential storage outside the repository.

Everything secret lives in one directory at 0700 with 0600 files. Writes are
atomic so an interrupted refresh cannot leave a truncated token file that would
lock the CLI out of the channel.
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any

from .errors import StoredFileError

DIRECTORY_MODE = 0o700
FILE_MODE = 0o600
CONFIG_DIR_ENV = "NEXTTANG_YOUTUBE_CONFIG_DIR"
CLIENT_SECRET_NAME = "client_secret.json"
TOKEN_NAME = "token.json"
UPLOAD_SESSION_NAME = "upload_session.json"


def config_dir() -> Path:
    """Resolve the configuration directory without creating it."""
    override = os.environ.get(CONFIG_DIR_ENV)
    if override:
        return Path(override).expanduser()
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".config"
    return base / "nexttang-youtube"


def ensure_config_dir() -> Path:
    """Create the configuration directory at 0700 and repair a loose mode."""
    directory = config_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=DIRECTORY_MODE)
    if permissions(directory) != DIRECTORY_MODE:
        directory.chmod(DIRECTORY_MODE)
    return directory


def client_secret_path() -> Path:
    return config_dir() / CLIENT_SECRET_NAME


def token_path() -> Path:
    return config_dir() / TOKEN_NAME


def upload_session_path() -> Path:
    return config_dir() / UPLOAD_SESSION_NAME


def permissions(path: Path) -> int:
    """Return the permission bits of an existing path."""
    return stat.S_IMODE(path.stat().st_mode)


def describe_permissions(path: Path) -> str:
    """Return permissions as a four-digit octal string, or 'absent'."""
    if not path.exists():
        return "absent"
    return format(permissions(path), "04o")


def read_json(path: Path) -> dict[str, Any] | None:
    """Read a JSON object, returning None when the file does not exist.

    A file that exists but is unreadable, damaged, or not an object raises a
    StoredFileError naming the file, so a truncated token is reported rather
    than surfacing as a traceback.
    """
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise _stored_file_error(path, exc.strerror or type(exc).__name__) from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise _stored_file_error(path, f"not valid JSON ({exc})") from exc
    if not isinstance(payload, dict):
        raise _stored_file_error(path, "not a JSON object")
    return payload


def write_secret_json(path: Path, payload: Any) -> None:
    """Write JSON atomically at 0600.

    The temporary file is created in the destination directory so os.replace is
    a rename within one filesystem, which is atomic. Readers therefore see
    either the previous document or the new one, never a partial write.
    """
    directory = path.parent
    directory.mkdir(parents=True, exist_ok=True, mode=DIRECTORY_MODE)
    if permissions(directory) != DIRECTORY_MODE:
        directory.chmod(DIRECTORY_MODE)

    handle, temporary_name = tempfile.mkstemp(dir=directory, prefix=f".{path.name}.", suffix=".tmp")
    temporary = Path(temporary_name)
    try:
        os.fchmod(handle, FILE_MODE)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    _sync_directory(directory)


def remove(path: Path) -> bool:
    """Delete a stored file, reporting whether anything was removed."""
    if not path.exists():
        return False
    path.unlink()
    return True


def _stored_file_error(path: Path, reason: str) -> StoredFileError:
    if path.name == TOKEN_NAME:
        hint = "Remove it and run 'nexttang-youtube auth login' to authorise again."
    elif path.name == CLIENT_SECRET_NAME:
        hint = "Re-download the Desktop app client JSON and install it there again."
    elif path.name == UPLOAD_SESSION_NAME:
        hint = (
            "Check 'videos list' for a partly finished upload, then remove the file and "
            "start the upload again."
        )
    else:
        hint = "Fix the file's permissions or replace it."
    return StoredFileError(f"cannot read {path}: {reason}", hint=hint)


def _sync_directory(directory: Path) -> None:
    """Flush the rename itself, so the replacement survives a power loss."""
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)
