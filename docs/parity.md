# Feature parity and verification

Behavior is based on the fresh Rails reference at `32b4144` and the Rust rewrite's
screen inventory at `ccece30`. The implementation uses a new V schema and browser
protocol. This matrix tracks product behavior, not identical HTML or Rails URLs.

| Area | Implemented behavior | Evidence |
| --- | --- | --- |
| First run | One workspace, first administrator, All Talk | HTTP integration; browser setup |
| Authentication | Case-insensitive login, bcrypt, persistent sessions, logout, CSRF/origin checks, rate limits | HTTP authorization and spoofed-header tests; browser sign-in/out |
| Invitations | Signup, rotation, duplicate-email handling, share/copy/QR | HTTP tests; browser invitation dialog |
| Devices | Single-use four-hour transfers, session listing/revocation | HTTP/WebSocket tests; browser transfer dialog |
| Rooms | Open/private creation, conversion, creator/admin controls, membership revocation, self-removal, deletion | HTTP and live revocation tests; browser room controls |
| Pings | One-to-one/group/bot conversations; one room per user set; immutable participants | HTTP uniqueness/permissions tests |
| Involvement | Everything, mentions, nothing, hidden; hidden-room management | HTTP tests; browser controls |
| Messages | Sanitized rich text, mentions, replies/quotes, author/admin edits/deletes, idempotency | HTTP/XSS/concurrent-send tests; browser actions |
| Editor | Bold, italic, underline, strike, highlight, headings, lists, quotes, code/languages, tables, safe rich paste, links/autolinks, mentions, drafts | HTTP sanitization; browser editor checks |
| Boosts | Unicode/text boosts, removal by owner, live updates | HTTP tests; browser search-result add/remove |
| History | 40-message pages, older/newer controls, 81-message around views, permalinks, last room | HTTP pagination; browser reconnect/history/send checks |
| Search | Access-scoped FTS5, literal operator words, pagination, recent searches | HTTP tests; browser 40→80 results with no duplicates |
| Realtime | New/edit/delete/boost events, typing, presence, disconnect updates, unread counts, reconnect | Two-client WebSocket tests; live browser receipt |
| Uploads | Preview before sending, remove queued file, progress, retries, image paste/drop, private downloads and ranges | Browser image queue/lightbox; HTTP MIME/access/range tests |
| Media | Images/thumbnails, audio/video playback, video posters, metadata | Native image helper and FFmpeg integration; browser decoding and media controls |
| Sounds | Campfire sound library, live playback when browser policy permits, manual replay | Browser sound control; vendored original assets |
| Link previews | Background Open Graph/title/description/image fetch; private images; invalidation on edits | Offline transport fixture, edit-during-fetch regression, real example.com browser fetch |
| People | Directory/search, profiles, avatars, pagination beyond 500 users | HTTP directory/profile tests; browser settings |
| Administration | Roles, room-creation restriction, ban/unban with public-IP bans, deactivation, workspace name/logo/CSS | HTTP permission/moderation tests; browser workspace form |
| Bots | Management/avatar/key rotation, message/file/boost APIs, paged history, direct/mention webhooks with replies | HTTP bot tests and real local webhook fixture; browser bot creation |
| Push | Session-bound subscriptions, VAPID/AES128GCM, mention/involvement/presence filtering, test notifications | RFC 8291 exact ciphertext vector; P-256 and recipient/session tests |
| PWA | Manifest, icons, installation help, notification service worker and deep links | HTTP asset checks; browser installation help |
| Presentation | Responsive sidebar/dialogs, light/dark themes, translated field help | Browser at 1280×800 and 390×844; no horizontal overflow |
| Operations | SQLite migrations, durable jobs/retries, maintenance, bounded media, health route, backups/restore | Job-limit and backup restore tests; resource reports |

## Remaining verification and scope limits

- The exact-main **compiler** requirement is unresolved under the retained memory
  cap; see [toolchain.md](toolchain.md). Current-main library sources are used.
- Real browser-provider push delivery has not been tested. The development
  browser's HTTP network origin is insecure. Test subscription and delivery over
  HTTPS before relying on push in a deployment.
- The reference's full screen inventory was used for audit, not run as a pixel
  or protocol equivalence suite. Cross-browser, physical-device, and accessibility
  certification have not been performed.
- The editor uses native contenteditable commands and a compact toolbar instead
  of Lexxy. Syntax highlighting includes 17 language definitions. Tables offer
  configurable initial dimensions and row/column controls. Pasted formatting is
  restricted to the app's safe tag/attribute whitelist.
- Linux x86-64, one app process, local SQLite. Uploads are limited to 16 MiB,
  outbound public previews to IPv4, and group selection to 500 people. The user
  directory is fetched in pages of 500 and assembled in the browser.
- No Rails database migration, sessions, signed-storage URL, Turbo/Action Cable,
  or external bot-client wire compatibility is promised.

The application implements the main product workflows, with these explicit
differences and validation gaps. It should not be described as independently
proven, complete equivalence to every reference behavior.

## Reproduce

`mise run test` launches the actual compiled app with temporary storage, then
checks HTTP, SQLite, WebSocket, uploads, jobs, bots, and restored backups. It leaves
separate server logs in `.build/test-server-PORT.log` and cleans up its processes.

`mise run test:v` verifies cryptographic/helper behavior independently of browser
code. Builds/tests are serialized inside the resource guard. Browser checks use
fictional accounts and are summarized in [browser-checks.md](browser-checks.md).
