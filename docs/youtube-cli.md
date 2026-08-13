# NextTang YouTube CLI

`nexttang-youtube` is a small read-first command line tool for the project's
YouTube channel. It is host tooling, not part of the FPGA build, and nothing in
it affects a bitstream or a board.

The channel ID is compiled into the tool. Every authenticated command resolves
the authorised channel through the API first and refuses to continue if that ID
does not match, so the tool cannot act on a different channel even when the
browser or the credential is signed in as someone else.

## Requirements

- Python 3.12, which the repository already requires. There are no third-party
  dependencies, so no virtual environment and no install step.
- A Google account that owns the channel.
- A Google Cloud project you control.

## Install

The entry point runs from the checkout:

```bash
./host/youtube/bin/nexttang-youtube status
```

Put it on `PATH` with a symlink if you prefer a bare command:

```bash
ln -s "$PWD/host/youtube/bin/nexttang-youtube" ~/.local/bin/nexttang-youtube
```

## Google Cloud prerequisites

Each operator sets up their own Cloud project. Credentials are never shared and
never committed.

1. Create a project in the [Google Cloud console](https://console.cloud.google.com/projectcreate).
2. Enable **YouTube Data API v3** and **YouTube Analytics API** in that project.
3. Configure the Google Auth Platform consent app. A personal Google account has
   no Workspace organisation, so the audience must be **External**.
4. Create an OAuth client of type **Desktop app**. Do not use a Web application
   client, and do not use a service account: a service account cannot own or act
   for a YouTube channel, so it cannot authorise these APIs.
5. Download the client JSON and install it as described below.

Billing is not required. None of these APIs bill against the free quota.

### Publishing status affects how often you log in

Google issues short-lived refresh tokens to External apps whose publishing
status is **Testing** when the app uses sensitive scopes, and the YouTube scopes
are sensitive. In practice that means re-running `auth login` about weekly.

Setting the app to **In production** stops that expiry. The app remains
unverified, so the consent screen shows a "Google hasn't verified this app"
warning and the project is capped at 100 users for its lifetime. Publishing does
not submit anything to Google for review. Verification is a separate process and
is only needed to remove the warning or to serve users beyond that cap.

## Secure OAuth setup

All credential material lives outside the repository:

```text
~/.config/nexttang-youtube/           mode 0700
~/.config/nexttang-youtube/client_secret.json   mode 0600
~/.config/nexttang-youtube/token.json           mode 0600
```

Install the downloaded client and lock it down, without letting it pass through
your shell history:

```bash
install -d -m 700 ~/.config/nexttang-youtube
mv ~/Downloads/client_secret_*.apps.googleusercontent.com.json \
   ~/.config/nexttang-youtube/client_secret.json
chmod 600 ~/.config/nexttang-youtube/client_secret.json
```

Then authorise:

```bash
nexttang-youtube auth login
```

The tool starts a local listener on `127.0.0.1` on an ephemeral port, prints a
Google consent URL, and waits up to 300 seconds for the redirect. It uses the
installed-application flow with PKCE (S256) and requests offline access. At the
account picker, choose the channel's own identity. Choosing a different account
is not dangerous: the channel guard refuses the mismatch and exits non-zero.

Token state is written atomically through a temporary file in the same
directory, so an interrupted refresh cannot leave a truncated token behind.

Never place credentials in the repository, in `llmwiki/`, in command arguments,
in environment files, or in test fixtures. The repository check rejects files
named like OAuth credentials even if they are force-added.

## Commands

Every command accepts `--json` for machine-readable output.

### Read commands

| Command | What it does |
| --- | --- |
| `status` | Reports readiness: credential paths and modes, granted scopes and capabilities, and the live channel identity. Add `--offline` to skip the API call. |
| `channel show` | Channel ID, title, handle, counts, and the current description. |
| `videos list` | Lists uploads. `--limit N` (default 25). `--no-details` skips the second call that adds privacy status and statistics. |
| `playlists list` | Lists playlists. `--limit N` (default 25). |
| `comments list` | Lists comment threads. `--unanswered` filters to threads the channel has not replied to. `--limit N` (default 25). |
| `analytics summary` | Channel analytics for a window. `--days N` (default 28, maximum 365). |

### Authorisation commands

| Command | What it does |
| --- | --- |
| `auth login` | Runs the consent flow. `--enable <capability>` requests one extra capability, repeatable. `--no-browser` prints the URL instead of opening it. |
| `auth status` | Shows stored authorisation without contacting Google. |
| `auth revoke` | Revokes the token at Google and deletes the local token file. The local file is removed even if the revocation call fails. |

### Write commands

All three are dry runs unless `--apply` is given.

| Command | What it does |
| --- | --- |
| `channel set-description --file FILE` | Replaces the channel description from a UTF-8 file. |
| `videos upload PATH --privacy private` | Uploads a video as private. `--privacy` is required and only `private` is accepted. |
| `comments reply COMMENT_ID --text-file FILE` | Posts one reply to one comment on the channel's own content. |

## Scopes and capabilities

`auth login` requests only read scopes by default:

| Scope | Purpose |
| --- | --- |
| `https://www.googleapis.com/auth/youtube.readonly` | Channel, video and playlist data |
| `https://www.googleapis.com/auth/yt-analytics.readonly` | Analytics reports |

Anything beyond that must be named explicitly with `--enable`:

| Capability | Scope added | Enables |
| --- | --- | --- |
| `comments-read` | `youtube.force-ssl` | `comments list` |
| `channel-write` | `youtube` | `channel set-description --apply` |
| `upload` | `youtube.upload` | `videos upload --apply` |
| `comment-reply` | `youtube.force-ssl` | `comments reply --apply` |

Two notes on this table.

`comments-read` is not a write capability, but it is not read-only either.
Google refuses `commentThreads.list` with `allThreadsRelatedToChannelId` under
`youtube.readonly` and requires `youtube.force-ssl`, which also permits editing
and deleting comments. There is no narrower scope for reading a channel's
comments. Granting it therefore widens the token beyond reading, which is why it
is a named opt-in rather than part of the default set.

Because `comments-read` and `comment-reply` share one scope, the tool records
which capabilities were requested at login and checks that list as well as the
scope. Granting comment reading does not enable replying. The scope is the real
security boundary and Google enforces it; the capability list is a local
interlock so one grant does not quietly imply another.

## Quota behaviour

A project that enables the YouTube Data API gets 10,000 units a day for most
endpoints, plus two separate daily buckets of 100 calls each for `search.list`
and `videos.insert`. Quota resets at midnight Pacific Time.

Costs relevant here:

| Call | Cost |
| --- | --- |
| `channels.list`, `playlistItems.list`, `playlists.list`, `videos.list`, `commentThreads.list` | 1 unit per page |
| `channels.update` | 50 units |
| `comments.insert` | 50 units |
| `videos.insert` | 1 call from the 100-per-day upload bucket |

Every authenticated command spends one extra unit on the channel identity check,
and a mutation spends another because the channel is re-resolved immediately
before the write. That is deliberate: one unit is cheap next to acting on the
wrong channel.

`videos list` reads the uploads playlist rather than calling `search.list`, so
listing videos costs 1 unit per page instead of consuming the separate
100-call-per-day search bucket.

Quota and rate-limit failures exit 6 and change nothing.

## Dry run and apply

Write commands describe the change and stop. They send no mutating request until
`--apply` is passed, and the tests assert that.

A dry run prints the operation, the target, the endpoint and quota cost, a
unified diff of the change, and any policy notes. Because a dry run only reads,
it works with read-only authorisation. Only `--apply` needs a write scope.

With `--apply` the tool re-resolves the channel through the API immediately
before the mutating call, so a token that changed hands between planning and
applying is caught. For `channel set-description` it also re-reads the current
branding and refuses to continue if it changed since the plan was shown, rather
than overwriting an edit someone made in the meantime.

### Channel updates are read-modify-write

`channels.update` replaces every mutable property in the part it is given, and a
property omitted from the request has its existing value deleted. The tool
therefore reads the complete `brandingSettings` object, changes only the
description, and writes the whole object back. The dry run lists the fields it is
preserving so you can see nothing is being dropped.

Never hand-write a `channels.update` request with only the field you want to
change. That deletes the rest.

### Replies are restricted to the channel's own content

`comments.insert` takes a `parentId` and will happily post under any comment,
including one on another channel's video. Verifying who is speaking is therefore
not enough. Before replying, the tool resolves the parent comment, resolves the
video it sits on, and refuses with exit 5 unless that video belongs to the pinned
channel. The check runs during the dry run as well, so a mistyped or copied ID is
caught before you are asked to approve anything, and the dry run prints the
resolved video and the author being replied to.

### Uploads stream, retry, and stop

Chunks are read from disk one at a time, so file size does not become memory use.
Each chunk request carries its own `Authorization` and `Content-Type` headers.
Transient failures (network errors and HTTP 408, 429, 500, 502, 503, 504) are
retried with exponential backoff and jitter, capped at 5 attempts per chunk and
64 seconds per wait, under an overall deadline of one hour. Before each retry the
tool asks the server how many bytes it actually holds, using a
`Content-Range: bytes */TOTAL` query, and resumes from there rather than assuming.
A permanent failure such as an expired session (404) fails immediately instead of
burning the deadline.

## Channel mismatch protection

The channel ID `UCzUSXeiPI3JMhlE5rmES4zA` is compiled in. Before any
authenticated operation the tool calls `channels.list` with `mine=true` and
compares the returned ID.

- A different ID aborts the command with exit 5 before anything else runs.
- An account controlling no channel, or more than one, is refused rather than
  guessed at.
- Title and handle are also displayed and compared, but they are mutable, so a
  difference there is a warning and not a refusal. Only the immutable ID decides.
- `auth login` verifies the channel before writing the token. A login that
  resolves to a different channel revokes the grant it just obtained and stores
  nothing, so a mistaken account choice leaves no token behind.
- Capability checks fail closed. A token that records no capabilities grants
  none, so an older or hand-edited token file cannot bypass the interlock.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Unclassified error |
| 2 | Usage error |
| 3 | No OAuth client credential installed |
| 4 | Not authorised, authorisation expired, or capability not granted |
| 5 | Authorised channel is not the pinned channel |
| 6 | Quota or rate limit |
| 7 | Other API error |

## API limitations

- **Uploads are private only.** Videos uploaded through `videos.insert` from an
  unverified API project created after 28 July 2020 are restricted to private
  viewing until the project passes a Google compliance audit. This tool also
  refuses any privacy value other than `private` by policy, so publishing is a
  deliberate manual step in YouTube Studio.
- **The made-for-kids declaration is not set.** The tool does not declare
  audience on your behalf. Set it in YouTube Studio before publishing anything.
- **Comment reply data can be incomplete.** `commentThreads.list` returns only
  some replies for a thread. When the tool cannot see every reply it reports the
  thread as `uncertain` rather than guessing, so a comment awaiting a reply is
  never silently classified as answered.
- **Analytics lag.** The Analytics API returns data up to the last day for which
  every requested metric is available, which is usually behind the end date.
- **No deletion, no publishing, no bulk operations.** Deleting videos, playlists
  or comments, publishing publicly, bulk replies, ownership changes and manager
  changes are all deliberately absent.

## Browser-only operations

The Data API cannot do these. Use YouTube Studio or Google account settings:

- changing the channel handle;
- profile picture, banner and watermark;
- channel links shown on the profile;
- channel name, which the API exposes read-only through `brandingSettings`;
- verification, monetisation, and Content ID;
- adding or removing channel managers and transferring ownership;
- moving a channel between Google accounts;
- audience and made-for-kids declarations;
- comment moderation settings and blocked words;
- publishing a private video to unlisted or public.

## Tests

The CLI is covered by the repository's normal gate:

```bash
make check
```

Tests use a mocked transport and never contact Google. They cover the channel
guard, pagination bounds, comment classification, dry-run and apply behaviour,
read-modify-write preservation, the upload privacy policy, secret redaction,
authentication and quota errors, and credential file permissions.
