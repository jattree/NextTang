"""OAuth 2.0 for an installed desktop application.

Follows Google's installed-app flow: a loopback redirect on an ephemeral port,
PKCE with S256, and offline access so the refresh token survives the session.
There is no service account anywhere in this design; a service account cannot
own a YouTube channel.

Reference: https://developers.google.com/identity/protocols/oauth2/native-app
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import secrets
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence

from . import storage
from .errors import AuthorisationError, MissingCredentialsError, ScopeError
from .redaction import register_secret
from .transport import Response, Transport

AUTHORISATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
REVOCATION_ENDPOINT = "https://oauth2.googleapis.com/revoke"

SCOPE_YOUTUBE_READONLY = "https://www.googleapis.com/auth/youtube.readonly"
SCOPE_ANALYTICS_READONLY = "https://www.googleapis.com/auth/yt-analytics.readonly"
SCOPE_YOUTUBE_MANAGE = "https://www.googleapis.com/auth/youtube"
SCOPE_YOUTUBE_UPLOAD = "https://www.googleapis.com/auth/youtube.upload"
SCOPE_YOUTUBE_FORCE_SSL = "https://www.googleapis.com/auth/youtube.force-ssl"

READ_ONLY_SCOPES: tuple[str, ...] = (SCOPE_YOUTUBE_READONLY, SCOPE_ANALYTICS_READONLY)

# Each capability is opt-in at login time and names exactly one scope.
#
# comments-read is not a write capability, but Google has no read-only scope
# that satisfies commentThreads.list with allThreadsRelatedToChannelId: that
# call returns 403 insufficientPermissions under youtube.readonly and needs
# force-ssl, which also permits replying and deleting. Granting it therefore
# widens the token beyond reading. The capability names are kept distinct so the
# grant is deliberate and so the reply command needs its own opt-in even when
# the scope is already present.
CAPABILITIES: dict[str, tuple[str, str]] = {
    "comments-read": (
        SCOPE_YOUTUBE_FORCE_SSL,
        "read every comment thread on the channel; Google requires force-ssl for this, "
        "and that scope also permits editing and deleting comments",
    ),
    "channel-write": (
        SCOPE_YOUTUBE_MANAGE,
        "update channel branding settings such as the description",
    ),
    "upload": (
        SCOPE_YOUTUBE_UPLOAD,
        "upload a video file as private",
    ),
    "comment-reply": (
        SCOPE_YOUTUBE_FORCE_SSL,
        "post a reply to an existing comment",
    ),
}
WRITE_CAPABILITIES = {
    name: value for name, value in CAPABILITIES.items() if name != "comments-read"
}

REFRESH_MARGIN_SECONDS = 120.0
LOGIN_TIMEOUT_SECONDS = 300.0

_CALLBACK_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>NextTang YouTube CLI</title></head>
<body style="font-family: system-ui, sans-serif; margin: 3rem;">
<h1>{heading}</h1><p>{message}</p><p>You can close this tab and return to the terminal.</p>
</body></html>
"""


@dataclass(frozen=True)
class ClientCredentials:
    """The OAuth client downloaded from the Google Cloud console."""

    client_id: str
    client_secret: str | None = None

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> "ClientCredentials":
        block = payload.get("installed") or payload.get("web") or payload
        if payload.get("web"):
            raise MissingCredentialsError(
                "the stored OAuth client is a Web application client",
                hint="Create an OAuth client of type 'Desktop app' and install that credential instead.",
            )
        client_id = block.get("client_id")
        if not client_id:
            raise MissingCredentialsError(
                "the stored OAuth client file has no client_id",
                hint="Re-download the Desktop app client JSON from the Google Cloud console.",
            )
        secret = block.get("client_secret")
        register_secret(secret)
        return cls(client_id=client_id, client_secret=secret)

    @classmethod
    def load(cls, path: Path | None = None) -> "ClientCredentials":
        target = path or storage.client_secret_path()
        payload = storage.read_json(target)
        if payload is None:
            raise MissingCredentialsError(
                f"no OAuth client credential at {target}",
                hint="Install the Desktop app client JSON there with mode 0600, then run 'auth login'.",
            )
        return cls.from_payload(payload)


@dataclass
class TokenState:
    """Stored authorisation. The refresh token is the durable part."""

    refresh_token: str
    scopes: tuple[str, ...] = ()
    access_token: str | None = None
    expires_at: float | None = None
    token_type: str = "Bearer"
    obtained_at: float | None = None
    client_id: str | None = None
    # Capabilities named at login. The scope is the security boundary; this is a
    # local interlock so one capability's scope does not silently enable another
    # command that happens to need the same scope.
    capabilities: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        register_secret(self.refresh_token)
        register_secret(self.access_token)

    def to_payload(self) -> dict[str, Any]:
        return {
            "refresh_token": self.refresh_token,
            "scopes": list(self.scopes),
            "access_token": self.access_token,
            "expires_at": self.expires_at,
            "token_type": self.token_type,
            "obtained_at": self.obtained_at,
            "client_id": self.client_id,
            "capabilities": list(self.capabilities),
        }

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> "TokenState":
        return cls(
            refresh_token=payload.get("refresh_token", ""),
            scopes=tuple(payload.get("scopes") or ()),
            access_token=payload.get("access_token"),
            expires_at=payload.get("expires_at"),
            token_type=payload.get("token_type", "Bearer"),
            obtained_at=payload.get("obtained_at"),
            client_id=payload.get("client_id"),
            capabilities=tuple(payload.get("capabilities") or ()),
        )

    def is_fresh(self, now: float, margin: float = REFRESH_MARGIN_SECONDS) -> bool:
        if not self.access_token or self.expires_at is None:
            return False
        return self.expires_at - margin > now


class AuthSession:
    """Owns the token lifecycle: load, refresh, persist, revoke."""

    def __init__(
        self,
        transport: Transport,
        *,
        credentials: ClientCredentials | None = None,
        token_path: Path | None = None,
        clock=time.time,
    ) -> None:
        self._transport = transport
        self._credentials = credentials
        self._token_path = token_path or storage.token_path()
        self._clock = clock
        self._state: TokenState | None = None

    @property
    def credentials(self) -> ClientCredentials:
        if self._credentials is None:
            self._credentials = ClientCredentials.load()
        return self._credentials

    @property
    def token_path(self) -> Path:
        return self._token_path

    def stored_state(self) -> TokenState | None:
        """Return the stored authorisation without contacting Google."""
        if self._state is not None:
            return self._state
        payload = storage.read_json(self._token_path)
        if payload is None:
            return None
        state = TokenState.from_payload(payload)
        if not state.refresh_token:
            return None
        self._state = state
        return state

    def require_state(self) -> TokenState:
        state = self.stored_state()
        if state is None:
            raise AuthorisationError(
                "no stored authorisation for the NextTang channel",
                hint="Run 'nexttang-youtube auth login'.",
            )
        return state

    def granted_scopes(self) -> tuple[str, ...]:
        state = self.stored_state()
        return state.scopes if state else ()

    def granted_capabilities(self) -> tuple[str, ...]:
        state = self.stored_state()
        return state.capabilities if state else ()

    def require_scope(self, scope: str, *, capability: str) -> None:
        """Refuse an operation whose scope and capability were not both granted.

        Two checks, because one scope can back more than one capability. The
        scope is what Google enforces; the capability is what the operator
        actually asked for at login.
        """
        if scope not in self.granted_scopes():
            raise ScopeError(
                f"the stored authorisation does not include {scope}",
                hint=(
                    f"This is deliberate. Re-run 'nexttang-youtube auth login --enable {capability}' "
                    "to grant it, then repeat the command."
                ),
            )
        granted = self.granted_capabilities()
        if granted and capability not in granted:
            raise ScopeError(
                f"the '{capability}' capability was not requested at login",
                hint=(
                    f"The token carries {scope}, but this command was not authorised. Re-run "
                    f"'nexttang-youtube auth login --enable {capability}' to enable it."
                ),
            )

    def access_token(self) -> str:
        """Return a usable access token, refreshing and persisting if needed."""
        state = self.require_state()
        if state.is_fresh(self._clock()):
            return str(state.access_token)
        return self.refresh()

    def refresh(self) -> str:
        """Exchange the refresh token for a new access token."""
        state = self.require_state()
        credentials = self.credentials
        form = {
            "client_id": credentials.client_id,
            "grant_type": "refresh_token",
            "refresh_token": state.refresh_token,
        }
        if credentials.client_secret:
            form["client_secret"] = credentials.client_secret

        response = self._post_form(TOKEN_ENDPOINT, form)
        if not response.ok:
            raise _token_error(response)

        payload = response.json()
        access_token = payload.get("access_token")
        if not access_token:
            raise AuthorisationError(
                "the token endpoint returned no access token",
                hint="Run 'nexttang-youtube auth login' to re-authorise.",
            )
        register_secret(access_token)
        now = self._clock()
        state.access_token = access_token
        state.expires_at = now + float(payload.get("expires_in", 3600))
        state.token_type = payload.get("token_type", "Bearer")
        state.obtained_at = now
        if payload.get("scope"):
            state.scopes = tuple(str(payload["scope"]).split())
        if payload.get("refresh_token"):
            register_secret(payload["refresh_token"])
            state.refresh_token = payload["refresh_token"]
        self.persist(state)
        return access_token

    def persist(self, state: TokenState) -> None:
        self._state = state
        storage.write_secret_json(self._token_path, state.to_payload())

    def revoke(self) -> dict[str, Any]:
        """Revoke at Google, then remove the local token whatever the outcome."""
        state = self.stored_state()
        if state is None:
            return {"revoked": False, "reason": "no stored authorisation", "local_state_removed": False}

        response = self._post_form(REVOCATION_ENDPOINT, {"token": state.refresh_token})
        removed = storage.remove(self._token_path)
        self._state = None
        result: dict[str, Any] = {
            "revoked": response.ok,
            "status": response.status,
            "local_state_removed": removed,
        }
        if not response.ok:
            payload = _safe_json(response)
            result["reason"] = payload.get("error_description") or payload.get("error") or "revocation refused"
        return result

    def _post_form(self, url: str, form: Mapping[str, str]) -> Response:
        body = urllib.parse.urlencode(form).encode("utf-8")
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        return self._transport.request("POST", url, headers=headers, body=body)


@dataclass
class LoginRequest:
    """A prepared authorisation request awaiting the user's browser consent."""

    authorisation_url: str
    redirect_uri: str
    state: str
    code_verifier: str
    scopes: tuple[str, ...]
    server: "_CallbackServer" = field(repr=False)


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Single-shot handler for the loopback redirect."""

    def do_GET(self) -> None:  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        parsed = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(parsed.query))
        self.server.captured = query  # type: ignore[attr-defined]
        if query.get("error"):
            page = _CALLBACK_PAGE.format(
                heading="Authorisation refused",
                message="Google reported: " + query["error"],
            )
            status = 400
        elif query.get("code"):
            page = _CALLBACK_PAGE.format(
                heading="NextTang YouTube CLI authorised",
                message="The authorisation code was received.",
            )
            status = 200
        else:
            page = _CALLBACK_PAGE.format(
                heading="Unexpected response",
                message="No authorisation code was present in the redirect.",
            )
            status = 400
        body = page.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: Any) -> None:
        """Silence the default logger. It would print the code-bearing URL."""


class _CallbackServer(http.server.HTTPServer):
    captured: dict[str, str] | None = None


def generate_code_verifier() -> str:
    """Create a PKCE code verifier: 43 to 128 unreserved characters."""
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode("ascii").rstrip("=")


def derive_code_challenge(verifier: str) -> str:
    """Derive the S256 challenge Google recommends for installed apps."""
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def build_authorisation_url(
    client_id: str,
    redirect_uri: str,
    scopes: Sequence[str],
    state: str,
    code_challenge: str,
) -> str:
    """Build the consent URL. It carries no token and no client secret."""
    parameters = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": " ".join(scopes),
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "access_type": "offline",
        "prompt": "consent",
        "include_granted_scopes": "false",
    }
    return f"{AUTHORISATION_ENDPOINT}?{urllib.parse.urlencode(parameters)}"


def start_login(credentials: ClientCredentials, scopes: Sequence[str]) -> LoginRequest:
    """Bind the loopback listener and prepare the consent URL."""
    server = _CallbackServer(("127.0.0.1", 0), _CallbackHandler)
    port = server.server_address[1]
    redirect_uri = f"http://127.0.0.1:{port}"
    verifier = generate_code_verifier()
    state = secrets.token_urlsafe(32)
    url = build_authorisation_url(
        credentials.client_id, redirect_uri, scopes, state, derive_code_challenge(verifier)
    )
    return LoginRequest(
        authorisation_url=url,
        redirect_uri=redirect_uri,
        state=state,
        code_verifier=verifier,
        scopes=tuple(scopes),
        server=server,
    )


def await_authorisation_code(request: LoginRequest, timeout: float = LOGIN_TIMEOUT_SECONDS) -> str:
    """Serve the single redirect and return the authorisation code."""
    server = request.server
    server.timeout = 1.0
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            server.handle_request()
            captured = server.captured
            if captured is None:
                continue
            if captured.get("error"):
                raise AuthorisationError(
                    f"Google refused the authorisation request: {captured['error']}",
                    hint="Re-run 'auth login' and grant the requested scopes for the NextTang channel.",
                )
            if captured.get("state") != request.state:
                raise AuthorisationError(
                    "the redirect state did not match the request",
                    hint="Discard this attempt and run 'auth login' again.",
                )
            code = captured.get("code")
            if code:
                register_secret(code)
                return code
        raise AuthorisationError(
            f"no authorisation response within {int(timeout)} seconds",
            hint="Run 'auth login' again and complete the consent screen in the browser.",
        )
    finally:
        server.server_close()


def exchange_code(
    transport: Transport,
    credentials: ClientCredentials,
    request: LoginRequest,
    code: str,
    *,
    capabilities: Sequence[str] = (),
    clock=time.time,
) -> TokenState:
    """Exchange the authorisation code for a refresh token and access token."""
    form = {
        "client_id": credentials.client_id,
        "code": code,
        "code_verifier": request.code_verifier,
        "grant_type": "authorization_code",
        "redirect_uri": request.redirect_uri,
    }
    if credentials.client_secret:
        form["client_secret"] = credentials.client_secret

    body = urllib.parse.urlencode(form).encode("utf-8")
    response = transport.request(
        "POST",
        TOKEN_ENDPOINT,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        body=body,
    )
    if not response.ok:
        raise _token_error(response)

    payload = response.json()
    refresh_token = payload.get("refresh_token")
    if not refresh_token:
        raise AuthorisationError(
            "Google returned no refresh token",
            hint=(
                "Revoke the app's access at https://myaccount.google.com/permissions and run "
                "'auth login' again so the consent screen is shown."
            ),
        )
    register_secret(refresh_token)
    register_secret(payload.get("access_token"))
    now = clock()
    granted = tuple(str(payload.get("scope", "")).split()) or tuple(request.scopes)
    return TokenState(
        refresh_token=refresh_token,
        scopes=granted,
        access_token=payload.get("access_token"),
        expires_at=now + float(payload.get("expires_in", 3600)),
        token_type=payload.get("token_type", "Bearer"),
        obtained_at=now,
        client_id=credentials.client_id,
        capabilities=tuple(capabilities),
    )


def _safe_json(response: Response) -> dict[str, Any]:
    try:
        payload = response.json()
    except Exception:  # noqa: BLE001 - a malformed error body must not mask the error
        return {}
    return payload if isinstance(payload, dict) else {}


def _token_error(response: Response) -> AuthorisationError:
    payload = _safe_json(response)
    error = payload.get("error", "unknown_error")
    description = payload.get("error_description", "")
    if error == "invalid_grant":
        return AuthorisationError(
            "the stored authorisation is no longer valid (expired, revoked, or reset)",
            hint="Run 'nexttang-youtube auth login' to authorise again.",
        )
    detail = f"{error}: {description}".strip(": ")
    return AuthorisationError(
        f"the OAuth token endpoint refused the request ({detail})",
        hint="Confirm the Desktop app client is installed correctly, then run 'auth login'.",
    )


def scopes_for(capabilities: Sequence[str]) -> tuple[str, ...]:
    """Resolve read-only scopes plus any deliberately requested extra scope."""
    scopes = list(READ_ONLY_SCOPES)
    for capability in capabilities:
        if capability not in CAPABILITIES:
            known = ", ".join(sorted(CAPABILITIES))
            raise AuthorisationError(f"unknown capability {capability!r}; known capabilities: {known}")
        scope = CAPABILITIES[capability][0]
        if scope not in scopes:
            scopes.append(scope)
    return tuple(scopes)


def describe_scopes(scopes: Sequence[str]) -> list[str]:
    """Explain each scope in one line for the consent preview."""
    descriptions = {
        SCOPE_YOUTUBE_READONLY: "read channel, video, playlist and comment data",
        SCOPE_ANALYTICS_READONLY: "read YouTube Analytics reports for the channel",
        SCOPE_YOUTUBE_MANAGE: "manage the YouTube account, including branding settings",
        SCOPE_YOUTUBE_UPLOAD: "upload video files to the channel",
        SCOPE_YOUTUBE_FORCE_SSL: "read, edit and permanently delete videos, ratings, comments and captions",
    }
    return [f"{scope}  ({descriptions.get(scope, 'no local description')})" for scope in scopes]


def dump_state_for_display(state: TokenState | None) -> dict[str, Any]:
    """Describe stored authorisation without disclosing any token."""
    if state is None:
        return {"authorised": False}
    return {
        "authorised": True,
        "scopes": list(state.scopes),
        "capabilities": list(state.capabilities),
        "client_id_suffix": (state.client_id or "")[-12:] or None,
        "access_token_present": bool(state.access_token),
        "access_token_expires_at": _format_epoch(state.expires_at),
        "obtained_at": _format_epoch(state.obtained_at),
    }


def _format_epoch(value: float | None) -> str | None:
    if value is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(value))
