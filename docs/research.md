# Decisions and evidence

Reference audit: 2026-10-06.

| Source | Revision |
| --- | --- |
| basecamp/once-campfire | `32b4144b5206304fa8d4c67455a753e2d3c16635` |
| basecamp/once-campfire-rust | `ccece30e8e160d8c3e05bf395ee55ee35962093b` |
| vlang/v master, refreshed after the initial audit | `1b4ecb9c05d4a09be1e12eff5725bca45494fdea` |

The Rails source, not the Rust performance claims, defines feature behavior.
The Rust port's `plans/rust-conversion.md`, `README.md`, and `parity/screens.yml`
identify edge cases and operational requirements worth carrying across.

- **HTTP:** V's maintained `veb`, with explicit routes, typed request structures,
  and request-scoped context. No Rails compatibility framework.
- **Data:** upstream `db.sqlite`, bound SQL, WAL and FTS5. Both reference apps use
  SQLite successfully. Rooms, memberships and message searches are relational;
  a remote database adds deployment and latency costs without a demonstrated need.
  Transactions protect first-run setup, direct-room uniqueness, and moderation.
- **Realtime:** upstream Linux `net.websocket.Reactor`. It supplies bounded queues,
  slow-consumer handling and one event loop rather than a thread per connection.
  Writes remain ordinary HTTP; websocket events carry updates, reads, and typing.
- **Frontend:** browser-native modules, semantic HTML, CSS, and a rich-text editor.
  This avoids the original Turbo/Action Cable coupling and a JS build framework.
  Campfire's content filters preserve tables, marks, and code language metadata;
  the V sanitizer does too. Highlight.js 11.12.0 was the npm latest on the audit
  date. Its core plus 17 language definitions occupy 92,885 bytes uncompressed;
  only code blocks with a selected language are highlighted, without server work.
- **Background work:** persistent SQLite jobs, one worker, bounded retries.
  The Rust rewrite explicitly loses in-memory queued work on crash; durable jobs
  avoid that limitation without Redis/Resque.
- **Development services:** Docker Caddy provides the same-origin reverse proxy.
  SQLite remains in the V process; no pretend database container is needed.
- **Safety during development:** serialized builds, 1536 MiB hard cgroup limit,
  zero swap, proactive stop at 1152 MiB. Runtime services also have memory limits.

Feature parity does not require Rails cookie, Active Storage URL, database schema,
or Action Cable wire compatibility. Vampfire uses its own schema and protocol.
Existing Campfire installations would need an explicit migration tool; none is
assumed by the requested rewrite. No changes are made to V or its libraries.

[Performance results](rust-vs-v.md) use the upstream comparison workloads on this
host after correctness checks. Published Rust numbers from different hardware
are not used as a Vampfire baseline.
