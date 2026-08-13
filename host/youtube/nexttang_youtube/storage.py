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

DIRECTORY_MODE = 0o700
FILE_MODE = 0o600
CONFIG_DIR_ENV = "NEXTTANG_YOUTUBE_CONFIG_DIR"
CLIENT_SECRET_NAME = "client_secret.json"
TOKEN_NAME = "token.json"


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


def permissions(path: Path) -> int:
    """Return the permission bits of an existing path."""
    return stat.S_IMODE(path.stat().st_mode)


def describe_permissions(path: Path) -> str:
    """Return permissions as a four-digit octal string, or 'absent'."""
    if not path.exists():
        return "absent"
    return format(permissions(path), "04o")


def read_json(path: Path) -> Any:
    """Read a JSON document, returning None when the file does not exist."""
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


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


def _sync_directory(directory: Path) -> None:
    """Flush the rename itself, so the replacement survives a power loss."""
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)
