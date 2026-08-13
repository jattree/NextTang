"""Strip credential material out of anything the CLI prints.

Two layers. Pattern rules catch the shapes secrets arrive in (JSON fields, query
parameters, bearer headers). The runtime registry catches the exact values this
process is holding, which covers error text no pattern anticipated.
"""

from __future__ import annotations

import re

PLACEHOLDER = "[redacted]"
MINIMUM_REGISTERED_LENGTH = 8

SECRET_JSON_KEYS = (
    "access_token",
    "client_secret",
    "code",
    "code_verifier",
    "id_token",
    "refresh_token",
    "token",
)
SECRET_QUERY_KEYS = (
    "access_token",
    "client_secret",
    "code",
    "code_verifier",
    "id_token",
    "refresh_token",
    "token",
)

# The key quotes are optional so prose such as `access_token: "ya29..."` in an
# error message is masked as well as a strict JSON body.
_JSON_FIELD = re.compile(
    r'("?(?:' + "|".join(SECRET_JSON_KEYS) + r')"?\s*:\s*)"[^"]*"',
    re.IGNORECASE,
)
_QUERY_PARAM = re.compile(
    r"((?:[?&])(?:" + "|".join(SECRET_QUERY_KEYS) + r")=)[^&\s\"']+",
    re.IGNORECASE,
)
_BEARER = re.compile(r"(Bearer\s+)[A-Za-z0-9._~+/\-]+=*", re.IGNORECASE)
_AUTH_HEADER = re.compile(r"(Authorization\s*[:=]\s*)\S+", re.IGNORECASE)

_registered: set[str] = set()


def register_secret(value: str | None) -> None:
    """Record a live secret so it is masked wherever it later appears."""
    if value and len(value) >= MINIMUM_REGISTERED_LENGTH:
        _registered.add(value)


def forget_secrets() -> None:
    """Drop the runtime registry. Used by tests and after revocation."""
    _registered.clear()


def redact(text: str) -> str:
    """Return text with credential material replaced by a placeholder."""
    if not text:
        return text
    result = text
    for secret in sorted(_registered, key=len, reverse=True):
        result = result.replace(secret, PLACEHOLDER)
    result = _JSON_FIELD.sub(rf'\1"{PLACEHOLDER}"', result)
    result = _QUERY_PARAM.sub(rf"\1{PLACEHOLDER}", result)
    result = _BEARER.sub(rf"\1{PLACEHOLDER}", result)
    result = _AUTH_HEADER.sub(rf"\1{PLACEHOLDER}", result)
    return result


def redact_url(url: str) -> str:
    """Return a URL safe to display, with any credential query value masked."""
    return redact(url)


def summarise_secret(value: str | None) -> str:
    """Describe a secret without disclosing it."""
    if not value:
        return "absent"
    return f"present ({len(value)} characters)"
