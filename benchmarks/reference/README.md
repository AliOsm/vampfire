# Reference Campfire benchmark

Uses [`basecamp/once-campfire-rust`'s `bench/run`](https://github.com/basecamp/once-campfire-rust/blob/ccece30e8e160d8c3e05bf395ee55ee35962093b/bench/run),
its Rust load generator and the original Rails parity seed. Application sources
and binaries are unchanged. `loadgen.patch` and `vampfire.rs` adapt the client.

## Run

On this Linux host (six cores, Docker, systemd user session, mise, `patch`):

```sh
mise install rust@1.98.1
mise run bench:reference:prepare
mise run bench:reference:smoke
mise run bench:reference
```

The runner prints its result directory. Summarize that directory with
`python benchmarks/reference/report.py DIRECTORY`; add `--export DESTINATION`
to retain the JSON/CSV evidence outside `.build`. The summary records expected
and completed scenarios, errors, and each metric's sample count. Missing latency
or upload results stay null; disconnected fan-out clients are failures, not
successful zero-latency deliveries. Repetition medians are not pooled percentiles.

Preparation expects the sibling `once-campfire-rust` checkout at `ccece30` and
initializes its pinned Rails submodule `90b3300`. If absent, it clones the pinned
checkout. Images are immutable official amd64 production images. Rails is used
only to generate the exact seed; this comparison measures Rust and V.

Runs use fresh storage, four server CPUs (0–3), two load-generator CPUs (4–5),
and loopback HTTP/1.1 keepalive. No User-Agent is sent. `Accept-Encoding: gzip`
is offered, as upstream; V currently returns identity. WebSockets are uncompressed.
Servers run sequentially. Three repetitions alternate Rust/V, V/Rust, Rust/V.
HTTP: 2-second c=4 warmup per route, then 8 seconds at c=1,16,64. Fan-out: 100,
500,1000 clients; 30 messages 200 ms apart, then four posters for 15 seconds and
the original drain periods. Upload: five repetitions of `black_hole.jpg` (505,420
bytes). These are `bench/run` defaults. A later published run used 100/1000/5000/
10000 connections; V's unchanged 2000-connection cap rules out its larger cases.

Both apps run natively in the same resource guard. Rust's unmodified official
production executable, libvips, FFmpeg and supporting libraries are extracted from
the pinned image; both apps use host glibc. Rust keeps five SQLite readers, three
workers per job kind, and its release build (fat LTO, one codegen unit). V uses its
existing release binary, four HTTP workers, four SQLite connections, one job
worker, and the upstream reactor. Both servers get four CPU cores. Readiness time
is process start to `/up`, with a warm filesystem cache, not machine cold boot.

The seed has 10 users, 11 rooms, 169 messages, 39 memberships, and 131 messages in
the busy room. V receives the same original message bodies, search text, people,
membership choices, boosts and media. Message IDs are translated into chronological
order because V pages by ID. Each app generates its own media derivatives. External
push/webhook endpoints point at closed localhost ports, as in the original harness.
Both use SQLite WAL/NORMAL; each implementation's normal caches/queues stay enabled.
Writes and fan-out grow the database during each run. As upstream uses fixed time
windows, faster servers accumulate more messages before the later scenarios.

## Workload mapping

| Workload | Rust | V |
| --- | --- | --- |
| Room view | `/rooms/:id`, rendered HTML with 40 messages | Shell + bootstrap + rooms + users + 40 messages: five sequential HTTP requests per logical operation |
| Earlier messages | `/rooms/:id/messages?before=…`, 40 rendered messages | `/api/rooms/:id/messages?before=…`, same 40 messages as JSON |
| Sidebar | `/users/me/sidebar`, rendered HTML | `/api/rooms`, JSON rendered in the browser |
| Search | `/searches?q=coffee`, 13 rendered matches | `/api/search?q=coffee`, same 13 matches as JSON, reversed display order |
| Avatar | Jason's generated 512×512 WebP | Jason's generated 640×640 JPEG (V's current media pipeline) |
| Static CSS | First stylesheet scraped by upstream (`_reset`, 1218 bytes) | Whole `app.css` (30105 bytes) |
| Health | `/up`, HTML | `/up`, JSON |
| Post | Form POST, rendered Turbo response | JSON POST, JSON response; same text and unique client ID |
| Fan-out | Action Cable subscriptions and Turbo broadcasts | V room subscription and JSON broadcasts; same marked messages, connection count, pacing and delivery accounting |
| Upload | Multipart message, fetch derived image | Upload, attach to message, poll until processed, fetch derived image |

These are application workflows, **not identical payloads or a language-only
comparison**. Browser JavaScript, layout and rendering are excluded on both sides.
V's room sequence includes bootstrap data and is deliberately not just a static
shell benchmark. The V browser fetches rooms and users concurrently; this client
serializes all five requests on one keepalive connection. Its room latency is a
server request-sequence measurement, not browser page-load time. Other HTTP data
rows are more narrowly comparable. Asset sizes,
view rendering, gzip and caching differences remain visible in the raw evidence.

## Measurement corrections and safeguards

- Upstream upload selects the first `<img>`, the sender's avatar. We retain this
  metric and run a separate Rust `--actual-thumbnail 1` series selecting the
  Active Storage representation. The useful comparison uses actual thumbnails.
  Both series warm media code; the original series precedes the corrected one.
- Added `post_errors` exposes failures upstream's fan-out poster excludes from
  its successful-post count. Histograms, markers, connection gate, pacing and
  drain calculations remain upstream. Complete delivery means every requested
  client received each message; receipt counts are not confused with unique posts.
- Before timing, the harness checks response statuses/counts. After each pair it
  checks the identical message IDs (through the translation), including order for
  room/history. A V room operation counts all five HTTP responses in latency/bytes.
- Process CPU includes worker threads and completed media children; one core is
  100%. RSS is sampled every 100 ms, summing the server and live children. Peaks
  are sampled peaks, not exact allocation maxima. Client CPU is recorded separately.
  CPU per operation covers the measured window; it does not include the future
  cost of background jobs still queued when the app stops.
- Every heavy command uses the existing 1536 MiB/no-swap guard and stops at
  1152 MiB. Final comparisons also set `memory.high=768 MiB`, an earlier kernel
  reclamation/throttling threshold. This keeps reclaimable WAL file cache from
  filling the guard before Linux begins reclaiming it. The hard/early-stop caps
  are unchanged. Applications and the load generator share this budget and run
  sequentially. A shared lock serializes experiments.
- Request logging stays at application defaults. A draining sink on client CPUs
  rotates native logs at 32 MiB (two files). Temporary servers are removed;
  logs, per-scenario results and isolated databases remain under `.build/comparison`.
- Two preliminary container/native attempts are excluded from final medians.
  One completed Rust's workload but stopped during an unbounded 1.1 GB log copy.
  After bounding logs, V's deliberately failing push retries accumulated a
  1.00 GiB WAL during writes, crossing the guard via file cache while server RSS
  was about 46 MiB. Neither stop was an OOM. Final native runs retain failing
  notification endpoints, record WAL growth/jobs, and apply the same earlier
  cache-pressure threshold to both applications.
- Before each full run, wait up to 60 seconds for one-minute load below 1.5 and
  record the observed load. This is a shared six-core host, not the eight-core
  allocation or Ryzen processor in the published Ruby/Rust numbers. Do not compare
  absolute results across those machines. High client CPU can limit throughput.

The default fan-out scenario connects up to 50 sockets concurrently, then waits
one second after subscription readiness before posting. This includes the app's
normal presence broadcasts during connection bursts. It is not a test of already
established, gradually connected clients. A failed scenario stops that app's
remaining scenarios for the repetition; the next repetition uses fresh storage.
`additional.py` can measure a skipped case on a fresh seed without mixing it into
the original series. For example, after the main run has stopped:

```sh
python scripts/resource_guard.py --report-dir .build/resource-reports \
  --memory-high-mib 768 --timeout 600 -- \
  python benchmarks/reference/additional.py cable --apps vampfire \
  --clients 500 1000 --repetitions 1 --out .build/comparison/isolated-cable
python scripts/resource_guard.py --report-dir .build/resource-reports \
  --memory-high-mib 768 --timeout 600 -- \
  python benchmarks/reference/additional.py upload \
  --out .build/comparison/isolated-upload
```

The adapter logs at most five WebSocket errors/close frames per follow-up process.
The final primary series used the same adapter without these error-path diagnostics;
each series records its client binary hash. CPU pinning does not exclude unrelated
host jobs. Host contention observed during a run must accompany its reported results.

The V toolchain limitation from [the main project](../../docs/toolchain.md) still
applies. No V compiler/library patches, application optimizations, or upstream
changes are part of this comparison. The load generator is upstream MIT-licensed;
see `UPSTREAM-LICENSE`.

`browser.py rust` / `browser.py vampfire`, wrapped in the same resource guard,
starts a temporary seeded server on port 4390 for unmeasured browser checks. It
exits after four minutes or when `.build/comparison/browser-stop` is created.
Prefer the T3 preview tools. If their host is explicitly unavailable, `--check`
uses `browser_check.cjs` with an installed Playwright module; `PLAYWRIGHT_MODULE`
can specify its absolute path. This fallback and the server share the guard.
It uses fresh browser contexts and leaves the existing demo server untouched.
Alongside login/history/search, V's check sends short, long Unicode, and short
messages between two users and verifies both WebSocket receipts and rendered text.
