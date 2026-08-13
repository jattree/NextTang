# nexttang-youtube

Read-first CLI for the project's YouTube channel. Host tooling only; nothing here
affects the FPGA build.

```bash
./bin/nexttang-youtube status
```

Setup, commands, scopes, quota, and the dry-run and apply rules are documented in
[docs/youtube-cli.md](../../docs/youtube-cli.md).

Standard library only, so it runs on the same Python 3.12 the repository already
requires, with no install step. Tests live in the repository's `tests/` directory
and run under `make check`.
