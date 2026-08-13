"""Typed failures with stable exit codes.

Exit codes are part of the CLI contract because scripts and the Codex skill
branch on them. Do not renumber an existing code.
"""

from __future__ import annotations

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_NO_CREDENTIALS = 3
EXIT_AUTH_REQUIRED = 4
EXIT_CHANNEL_MISMATCH = 5
EXIT_QUOTA = 6
EXIT_API = 7


class CliError(Exception):
    """Base class for every failure the CLI reports rather than traces."""

    exit_code = EXIT_ERROR

    def __init__(self, message: str, *, hint: str | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.hint = hint


class UsageError(CliError):
    exit_code = EXIT_USAGE


class MissingCredentialsError(CliError):
    """The OAuth client credential has not been installed locally."""

    exit_code = EXIT_NO_CREDENTIALS


class AuthorisationError(CliError):
    """No stored authorisation, or the stored authorisation no longer works."""

    exit_code = EXIT_AUTH_REQUIRED


class ScopeError(AuthorisationError):
    """The stored authorisation lacks a scope the requested operation needs."""


class ChannelMismatchError(CliError):
    """The authorised channel is not the pinned NextTang channel."""

    exit_code = EXIT_CHANNEL_MISMATCH

    def __init__(self, expected: str, observed: str, *, observed_title: str | None = None) -> None:
        described = observed_title or "unknown title"
        super().__init__(
            f"authorised channel {observed} ({described}) is not the pinned channel {expected}",
            hint="Run 'nexttang-youtube auth revoke', then log in again and pick the NextTang channel.",
        )
        self.expected = expected
        self.observed = observed
        self.observed_title = observed_title


class ForeignContentError(CliError):
    """The operation would act on content the pinned channel does not own.

    Distinct from ChannelMismatchError: the credential is correct, the target is
    not. Replying to a comment on someone else's video is the case that matters.
    """

    exit_code = EXIT_CHANNEL_MISMATCH


class QuotaError(CliError):
    """The API refused the call for quota or rate-limit reasons."""

    exit_code = EXIT_QUOTA


class ApiError(CliError):
    """The API returned an error that is not an auth, quota, or identity problem."""

    exit_code = EXIT_API

    def __init__(self, message: str, *, status: int | None = None, reason: str | None = None,
                 hint: str | None = None) -> None:
        super().__init__(message, hint=hint)
        self.status = status
        self.reason = reason
