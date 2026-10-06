# Vampfire

A Campfire rewrite in V: rooms, private conversations, rich messages, files, bots,
search, and live updates. Plain HTML/CSS/JavaScript, `veb`, SQLite WAL/FTS5, and V's
Linux WebSocket reactor. No Rails, Redis, frontend framework, or upstream V patches.

## Run locally

Requires Linux x86-64, [mise](https://mise.jdx.dev), Git, GCC, curl, util-linux
(`prlimit`), a working systemd user session, and Docker Compose.

```sh
mise trust
mise install
mise run setup
mise run dev
```

In another terminal, run `mise run services`. Open **http://localhost:8088** and
create your workspace. Docker supplies the bounded Caddy development proxy;
SQLite runs inside the app. Direct access also works at http://localhost:8080.

The V library checkout is unmodified main, pinned at `f34e871`. The executable
compiler is the official `vc` bootstrap from October 4, reporting `02d8026`.
**An exact-main self-hosted compiler could not be built within the memory cap.**
See [the toolchain record](docs/toolchain.md) before treating this as an exact-main
compiler validation.

## Included

- Open/private rooms and private group pings; membership and notification controls.
- Rich text, mentions, replies, tables, drafts, edits, deletion, boosts, and sounds.
- Queued file uploads, image/video previews, audio playback, private downloads.
- History/permalinks, full-text search, presence, typing, unread counts, reconnects.
- Profiles, avatars, invitations/QR codes, device transfers, account administration.
- Bot APIs/webhooks, link previews, Web Push, and an installable web app.

[Feature and verification matrix](docs/parity.md) · [Measured performance](docs/performance.md)

## Check it

```sh
mise run test       # builds and exercises the real HTTP/WebSocket app
mise run test:v     # RFC 8291 vector and application security helpers
mise run bench     # bounded local benchmark; writes JSON evidence
```

29 integration scenarios and five V security tests passed during development.
Desktop/mobile browser flows were checked separately. Real browser-provider push
delivery still needs verification over HTTPS; cryptography and recipient targeting
are tested. This is not a claim that all reference screenshots or every browser
have passed an automated equivalence suite.

[Operation, backups, and configuration](docs/operations.md) · [Bot API](docs/bots.md)
· [Decisions and sources](docs/research.md)

MIT licensed; see [third-party notices](THIRD_PARTY.md).
