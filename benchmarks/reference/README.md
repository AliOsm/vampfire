# Reference Campfire benchmark

Runs the original Campfire Ruby/Rust workload shapes using the current
[shared verification client](https://github.com/basecamp/once-campfire-verification/tree/8c7570427490fa7e19311b81837c63162c763494).
`loadgen.patch` and `vampfire.rs` adapt protocols; scheduling, histograms, pacing,
and complete-delivery accounting remain upstream. Rust is unmodified;
[V application adaptations](../../docs/optimizations.md) are under test.

## Reproduce

Requires Linux, six CPUs, Docker, a systemd user session, mise, GCC and `patch`:

```sh
mise run setup
mise run build
mise install rust@1.98.1
mise run bench:reference:prepare
mise run bench:reference:smoke
mise run bench:reference
```

The runner prints its result directory. Run `python benchmarks/reference/report.py
DIRECTORY --export DESTINATION` to retain JSON/CSV evidence outside `.build`.
Summaries retain errors, missing cases, sample counts, ranges and repetition
medians; percentiles are not pooled across runs.
Fan-out metric distributions include only fully successful repetitions; the
recorded/successful counts and all raw failures remain in the report.

Preparation uses Rust `2e392fe`, verification `8c75704`, and the original Rails
fixture revision `90b3300`. Checkouts live under `.build/comparison`. Official
production images are digest-pinned. Rails only generates the original seed.
V seed previews are regenerated with the production binary before measurement.

## Conditions

- Three alternating repetitions: Rust/V, V/Rust, Rust/V, each with fresh storage.
- Four server CPUs (0–3), two client CPUs (4–5); native processes, loopback
  HTTP/1.1 keepalive, gzip offered, no User-Agent, uncompressed WebSockets.
- HTTP: 2 seconds of warmup at c=4, then 8 seconds at c=1/16/64 per route.
- Mixed reads: c=16 history/sidebar/search, 8 seconds, plus 10 message writes/s
  in HQ. This exercises cache invalidation during writes.
- Fan-out: 100/500/1000 clients, up to 50 concurrent handshakes, 30 paced messages
  200 ms apart, then four posters for 15 seconds with upstream drain periods.
- Upload: five repetitions of the original 505,420-byte `black_hole.jpg`.
- The original seed has 10 users, 11 rooms, 169 messages, 39 memberships, and
  131 busy-room messages. Text, memberships, boosts and original media match;
  V IDs are translated into chronological order. Each app creates its derivatives.
- Both use WAL/NORMAL. Normal caches, logging and job processing stay enabled.
  Push/webhook endpoints fail locally, as upstream. Faster servers accumulate
  more messages/jobs in each fixed time window before later scenarios.

Rust's bounded in-memory queues are best effort and can drop work when full;
V persists jobs and retries in SQLite. Write throughput therefore includes
different durability and retry work. Final V queue counts are reported explicitly.

Rust's release executable and media libraries come from the official image;
it runs with host glibc, five SQLite readers and three workers per job kind.
V uses `-prod`, GCC/LTO, Boehm GC, four HTTP workers, four SQLite readers, one
writer, isolated job workers and four upstream WebSocket reactors sharing the
original total connection/mailbox budgets. Exact flags,
source/binary hashes and toolchain identities accompany each run.

## Workload mapping

| Workload | Rust | V |
| --- | --- | --- |
| Room | One rendered HTML response, 40 messages | Shell + bootstrap + rooms + users + 40 messages: five sequential requests per operation |
| History | 40 rendered messages | Same 40 messages as JSON |
| Sidebar | Rendered HTML | JSON rendered by the browser |
| Search | 13 rendered matches | Same 13 matches as JSON, reversed display order |
| Avatar | Jason's 512×512 WebP | Jason's 640×640 JPEG |
| CSS | First stylesheet (`_reset`, 1,218 bytes) | Whole `app.css` (30,105 bytes) |
| Health | HTML | JSON |
| Write | Form POST, Turbo response | JSON POST/response; same text and unique client ID |
| Fan-out | Action Cable/Turbo broadcasts | Room subscriptions/JSON broadcasts; same markers and delivery accounting |
| Upload | Multipart message + derived image | Upload + message + readiness polling + derived image |

These are application workflows, not identical payloads or a language benchmark.
Browser rendering is excluded. The real V browser fetches rooms/users concurrently;
the room benchmark serializes its five requests on one connection. Larger upstream
5,000/10,000-client profiles exceed V's unchanged 2,000-connection configuration.

## Correctness and resources

Every timed and warmup HTTP response is validated. SQLite supplies the expected
message windows and content; responses do not supply their own expectations.
Acknowledged HTTP/mixed writes are checked against stored IDs, room, text and FTS
rows, including warmups. Fan-out requires every client to receive every posted
message, and includes post errors. Warmup/read failures invalidate the run.

The original upload client selects the sender's avatar first. That legacy status
measurement is retained separately; the comparison selects the actual Rust
representation. Both apps' actual thumbnails must decode into pixels after timing.
The V room adapter also validates intermediate API response shapes. JSON schema
and HTML presentation differences remain explicit.

Server CPU includes threads and completed media children; 100% means one core.
RSS includes live children and is sampled every 100 ms. CPU/op excludes work left
queued after measurement, so final job counts and peak WAL size are retained.
Client CPU and unaccounted host CPU are recorded; the latter includes the runner
kernel work and unrelated jobs. CPU affinity does not isolate this shared host. Before each
run, wait up to 60 seconds for one-minute load below 1.5 and record actual conditions.
Client validation can limit saturation throughput.

Heavy commands are serialized through the 1,536 MiB/no-swap guard, with proactive
stop at 1,152 MiB. Benchmarks set `memory.high=768 MiB` for earlier cache reclamation.
The apps and client share this budget. Logs drain on client CPUs and rotate at
32 MiB. Raw results, databases, logs and memory samples remain in `.build/comparison`.
A failed case stops that app's remaining scenarios for the repetition; later runs
use fresh seeds. Failures never become successful zero-latency results.

[The V toolchain limitation](../../docs/toolchain.md) applies: current-main library
sources, official portable bootstrap, no compiler/library patches. The client is
MIT-licensed; see `UPSTREAM-LICENSE`.

## Browser checks

Wrap `python benchmarks/reference/browser.py rust` (or `vampfire`) in the resource
guard to start an isolated server on port 4390 for four minutes. Prefer T3 preview.
When its host is unavailable, `--check` uses the installed Playwright module named
by `PLAYWRIGHT_MODULE`. Checks cover login/history/search; V additionally covers
live Unicode messages, drafts, reconnects, room-switch races, actual thumbnails,
original downloads and mobile layout. These checks do not prove full feature
parity or end-to-end delivery through real browser push providers.
