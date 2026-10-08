# Running Vampfire

## Configuration

Copy `.env.example` to `.env` when changing defaults. mise loads `.env` and the
private `.data/push.env` file automatically. Running the binary directly requires
exporting the same environment yourself.

| Variable | Default / purpose |
| --- | --- |
| `BIND` | `127.0.0.1`; HTTP listen address |
| `PORT` | `8080` |
| `BASE_URL` | `http://localhost:8080`; canonical URL and secure-cookie policy |
| `VAMPFIRE_DATA` | `.data`, resolved by mise to this repository |
| `TRUSTED_PROXIES` | Empty; comma-separated exact IPs of proxies you control |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | Generated once by `mise run push:keys` |

With the Docker proxy, set `BASE_URL=http://localhost:8088` and
`TRUSTED_PROXIES=127.0.0.1`. Caddy uses Linux host networking and forwards to the
loopback app. It is capped at 96 MiB with no swap and half a CPU. `mise run
services:stop` removes this development service.

For public deployment, terminate HTTPS at a trusted reverse proxy, set the HTTPS
`BASE_URL`, and expose only that proxy. Keep the data directory private to the
service account. Use one app process and a local filesystem: the WebSocket hub
and presence tracking do not implement multiple-instance coordination. The provided
Docker configuration is a development HTTP proxy, not a production TLS deployment.

The app has four HTTP workers, four SQLite readers and one writer. Connections
are leased only while executing SQL; writer transactions retain their lease.
Statements are cached per connection. Background checkpoints begin after another
1,000 WAL pages; at 10,000 pages a coordinated restart bounds normal growth, though
long or external readers can delay it. SQLite uses WAL and `synchronous=NORMAL`: committed work survives a process
crash, but recent commits can be lost after a machine/power failure. `/up` reports
process liveness. Monitor logs, disk space, and the durable job queue separately.

Four WebSocket reactor workers share a total 2,000-connection limit, 8,192 command
slots and 16 MiB of mailbox payloads. New peers go to the least-loaded worker.
Saturated broadcast producers can still overflow a mailbox and disconnect peers
with code 1013; this is a known capacity limit. The first five abnormal closes are
logged. A successful message POST confirms storage, not receipt by every peer.

## Files and jobs

Files live in `.data/uploads`; each upload is capped at 16 MiB. File access is
checked against ownership, shared rooms, avatars, or the workspace logo. Unknown
formats download as attachments. Full files and byte ranges stream to the client.
PNG/JPEG/GIF previews use V's native `stbi` helper in a bounded subprocess;
metadata-bearing or unsupported images, videos and audio use FFmpeg/ffprobe.
Both paths have dimension, memory and time limits.

Media processing, bot callbacks, notifications, and link previews use durable
SQLite jobs. Media, previews, notification expansion and push tests have separate
workers; webhooks and individual push deliveries each have two workers. Claims
are atomic, and commits wake the relevant queue. Failed work retries up to five total attempts,
then retains its error for inspection. On restart it releases abandoned locks.
Delivery is at least once; bot replies have stable idempotency keys.
Notification expansion commits its child jobs and parent removal together.

History, sidebar, directory and search responses share a 16 MiB cache with a
15-second lifetime, keyed by session and raw URI. Every request still authenticates;
SQLite commits invalidate cached responses. Static text assets have a separate
8 MiB budget, with compressed representations and ETags prepared at startup.

Inspect failed jobs with a SQLite client:

```sql
SELECT id, kind, attempts, error FROM jobs WHERE attempts >= 5;
-- After correcting the underlying problem, retry a selected job:
UPDATE jobs SET attempts=0, available_at=0, locked_at=0 WHERE id=123;
```

Unclaimed files are collected after a day, up to 100 per hourly maintenance run.
Expired sessions, transfers, and old rate-limit entries are also removed.

Public link previews use DNS-pinned IPv4 HTTP(S), standard ports, and private-IP
rejection on each redirect. IPv6-only preview hosts are currently unsupported.
Administrator-configured bot webhooks may target internal services and arbitrary
HTTP(S) ports. A bot key grants that bot's permissions; keep it out of logs and
shared screenshots.

## Web Push

Run `mise run push:keys` once, then restart using mise. The generator refuses to
overwrite existing keys. A secure browser origin and user-granted notification
permission are required. Under Profile → Devices & notifications, enable push
and use the test-notification control. Signing/encryption and recipient targeting
are tested locally; real provider delivery still requires an HTTPS browser test.
Startup validates that both VAPID keys are configured and match, or both are empty.

Subscriptions belong to a session. Logout, device revocation, deactivation, and
session expiry remove their subscriptions. Room involvement and current presence
control delivery. The service worker does not cache private chat data for offline
use.

## Backup and restore

Stop the app before copying the database and uploads together:

```sh
mise run backup
```

The backup contains a consistent SQLite snapshot checked with `integrity_check`,
uploads, push keys if present, and metadata. Its directory is private. Copy it to
separate storage; a second directory on the same disk is not disaster recovery.

To restore, stop the app, preserve the existing data directory, and copy the chosen
backup into `.data` (or set `VAMPFIRE_DATA` to the restored directory). Restore the
same push keys, retain your `.env`, and restart. An integration scenario restores a
backup into a new process and verifies both message history and attachment bytes.

This is a new schema, version 1. It does not import a Rails Campfire database,
cookies, signed URLs, or Action Cable clients. Such a migration needs a separate,
explicit conversion tool.
