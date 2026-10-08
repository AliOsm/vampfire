# Rust optimizations adapted to V

Audit target: Rust [`2e392fe`](https://github.com/basecamp/once-campfire-rust/commit/2e392fe1c839541c3cbfcf0b980ea36310a37393).
V uses unmodified upstream sources; these are application changes.

| Rust change | Vampfire adaptation |
| --- | --- |
| [Cached statements](https://github.com/basecamp/once-campfire-rust/commit/4dd3ff3), [inline reads](https://github.com/basecamp/once-campfire-rust/commit/ce03264), short connection ownership | Four readers, one writer, 256 cached statements per connection; leases end before hashing, rendering, network or media work. |
| [Background WAL checkpoints](https://github.com/basecamp/once-campfire-rust/commit/12197b5), [restart coordination](https://github.com/basecamp/once-campfire-rust/commit/2d853c4) | Passive checkpoints after 1,000-page growth; coordinated restart at 10,000 pages. Long or external readers can delay a checkpoint. |
| [Positional rows](https://github.com/basecamp/once-campfire-rust/commit/33c46d8), [stored create responses](https://github.com/basecamp/once-campfire-rust/commit/2e7f20d), batched membership writes | Explicit hot-path columns, bound association batches, no text-create reread, bulk membership changes, no-op activity/read updates avoided. |
| [FTS ordering](https://github.com/basecamp/once-campfire-rust/commit/4c2ac40), [bounded search probe](https://github.com/basecamp/once-campfire-rust/commit/b1d751b) | Newest-first FTS probe capped at 1,000 candidates, with membership-scoped fallback; V retains 40-result pagination. |
| [Finished response cache](https://github.com/basecamp/once-campfire-rust/commit/d09811c), raw-query keys and gzip reuse | 16 MiB cache keyed by session and raw URI, 15-second lifetime, fresh authentication, SQLite generation checks, cached identity/gzip bodies and ETags. Static text assets have a separate 8 MiB budget. |
| [Independent job queues](https://github.com/basecamp/once-campfire-rust/commit/00b3248), [bounded push workers](https://github.com/basecamp/once-campfire-rust/commit/d7d3a09) | Separate media, preview, notification, push and webhook workers; commit-triggered wakeups and atomic claims. Per-recipient retries and notification expansion are durable. |
| [Media outside SQLite](https://github.com/basecamp/once-campfire-rust/commit/ff7f432), [shorter subprocess polling](https://github.com/basecamp/once-campfire-rust/commit/5cb64af) | Native `stbi` image helper under the existing 512 MiB subprocess cap, ffmpeg fallback, 5 ms polling, streamed full/range downloads. |
| [Bounded rich-text parsing](https://github.com/basecamp/once-campfire-rust/commit/ffde107), [cheaper sanitization](https://github.com/basecamp/once-campfire-rust/commit/2f9e03c), bounded Open Graph parsing | Complexity checks before DOM construction, plain-text fast path, one URL normalization, bounded document-head parsing. |
| [Preserved editors](https://github.com/basecamp/once-campfire-rust/commit/c5799c3), [reconnect ordering](https://github.com/basecamp/once-campfire-rust/commit/322df75) | Existing drafts/modal isolation retained; stale socket callbacks rejected and sidebar/read requests coalesced. |
| [Bounded Cable delivery](https://github.com/basecamp/once-campfire-rust/commit/6c60c7b) | Indexed recipients, sends outside hub locks, unchanged presence suppressed, explicit subscriber acknowledgements; four reactors partition the original total limits. Saturation can still overflow their mailboxes. |

Some changes belong to Rust's stack rather than this application:

- Askama/HTML fragment splicing is represented by cached complete JSON responses and the static shell. V does not render the same HTML pages.
- V already uses compiled routes, avoids per-page User-Agent parsing, and does not make the duplicate upload MD5 pass removed in Rust. Rust's updated-message index serves a refresh query V does not issue.
- Jemalloc, zlib-rs SIMD and Rust-specific allocation changes do not transfer to V's upstream runtime. Production builds retain `-prod`, GCC/LTO and Boehm GC.
- Rust uses bounded in-memory job queues and can drop work when full (`crates/campfire/src/jobs.rs`). V retains durable jobs and retries; copying that shortcut would change restart/delivery behavior. This adds SQLite work, especially with the benchmark's deliberately failing notification endpoints.
- Upstream V's reactor exposes neither shared preframed broadcasts nor per-message deflate negotiation. Those Rust transport optimizations remain unavailable without replacing or changing the upstream transport.
- The bounded reactor mailbox can reject a broadcast burst and mark affected connections overloaded. Four workers improve parallelism but did not eliminate this in the isolated 1,000-client test. That failure is reported, not treated as a successful zero-latency result.
- `veb` buffers incoming multipart bodies; downloads now stream, but upload spooling would require a different HTTP transport. Uploads remain capped at 16 MiB.
- Outbound curl retains DNS pinning, certificate checks, response-size caps and deadlines. Replacing it with V's HTTP client would lose the pinned-address/whole-request deadline controls used here.

The benchmark includes response/content validation, persisted acknowledgement audits,
complete WebSocket delivery and reads under a 10-message/second writer. These checks
do not establish complete Campfire parity or delivery through real browser push providers.
