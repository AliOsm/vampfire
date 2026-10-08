# Campfire: Rust vs V

Measured **2026-10-08**, after adapting the applicable [Rust optimizations](optimizations.md).
V has higher cached read throughput and lower process memory. Rust is faster at
writes, the room request sequence, startup and uploads, with lower p99 latency
in most workloads. **V's 1,000-client saturation delivery remains unreliable.**

Three alternating repetitions used fresh storage and the original
[Campfire Ruby/Rust workload shapes and seed](../benchmarks/reference/README.md).
Intel i5-8500: server CPUs 0–3, client CPUs 4–5, native release binaries, loopback
HTTP/1.1 keepalive, gzip offered, uncompressed WebSockets. V used **`-prod`,
GCC/LTO and Boehm GC**. Both apps shared a memory cap with their client; the host
was not isolated. These are application measurements, not a language ranking.

## HTTP

Medians at **16 concurrent clients**, eight seconds after two seconds of warmup.
Latency is milliseconds; percentiles are medians of each run's percentiles.

| Workload | Rust ops/s | V ops/s | Rust p50 / p99 | V p50 / p99 |
| --- | ---: | ---: | ---: | ---: |
| Room request sequence¹ | 21,142 | 3,208 | 0.668 / 2.607 | 4.779 / 8.647 |
| Earlier 40 messages | 20,885 | 30,011 | 0.685 / 2.519 | 0.373 / 2.971 |
| Sidebar | 23,686 | 32,482 | 0.587 / 2.353 | 0.351 / 2.893 |
| Search, 13 matches | 23,298 | 33,089 | 0.591 / 2.375 | 0.349 / 2.895 |
| Persist a message | 2,082 | 926 | 7.111 / 20.095 | 14.895 / 54.847 |
| Avatar² | 58,839 | 27,792 | 0.245 / 0.768 | 0.391 / 3.553 |
| CSS² | 63,807 | 47,279 | 0.224 / 0.687 | 0.210 / 2.589 |
| Health | 38,884 | 57,837 | 0.385 / 1.221 | 0.181 / 2.293 |

¹ Rust renders HTML in one request. V serves its shell plus four sequential JSON
API requests per operation; its browser fetches rooms/users concurrently. This
is a server request sequence, not browser page-load time. Other data routes
also return HTML versus JSON, with different compression and payload sizes.

² Rust's CSS is a 1,218-byte reset; V's is a 30,105-byte full stylesheet. Avatars
are 512×512 WebP versus 640×640 JPEG. These are different representations.

At **64 writers**, Rust delivered **2,072 messages/s**, V **624.7 messages/s**;
p99 was **48.74 / 176.64 ms**. Rust's job queues are bounded, in-memory and best
effort; V persists jobs and retries in SQLite. Their write work is not equivalent.

## Reads while messages arrive

Sixteen readers plus **10 writes/second**, eight seconds, on the same seed.
Writes exercise response-cache invalidation. CPU includes the concurrent writer.

| Workload | Rust ops/s | V ops/s | Rust p99 ms | V p99 ms |
| --- | ---: | ---: | ---: | ---: |
| Earlier 40 messages | 16,953 | 17,622 | 8.679 | 8.099 |
| Sidebar | 22,303 | 26,365 | 2.833 | 5.679 |
| Search | 21,824 | 24,157 | 3.701 | 6.259 |

The history advantage falls from **44%** in the read-only workload to **4%** with
writes, and the mixed-history repetition ranges overlap. The seed is small:
10 users, 11 rooms, 169 messages, and 131 messages in the busy room.

## WebSocket fan-out

Throughput counts messages delivered to **every recipient** under four saturated
posters for 15 seconds. Paced p99 measures POST start to the last recipient for
30 messages sent 200 ms apart. Metric distributions exclude failed repetitions;
all failures remain in the raw results.

| Recipients | Rust messages/s | V messages/s | Rust paced p99 ms | V paced p99 ms | Completed runs, Rust / V |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 849.4 | 272.8 | 12.559 | 43.967 | 3/3 / 3/3 |
| 500 | 234.8 | 252.5 | 31.199 | 86.015 | 3/3 / 3/3 |
| 1,000 | 125.1 | **Unreliable** | 43.647 | — | 3/3 / **2/3** |

V's two successful 1,000-client runs delivered 143.0–189.2 messages/s, with paced
p99 of 67.519–108.031 ms. In the failed run, all clients subscribed and all 30
paced messages arrived, but only **607 of 3,321** saturation messages reached
everyone; **1,000 clients failed**. This does not establish reliable capacity.

An isolated reproduction identified **`1013 Mailbox full`** closes. Four reactors
partition the original total budgets (2,000 connections, 8,192 command slots,
16 MiB mailbox payloads); they did **not** eliminate the failure. All **three
isolated 1,000-client saturation repetitions failed**, without memory-high,
socket-throttling or OOM events. [Diagnostic evidence](validation/20261008-rust-architecture/saturation-reset/).
No V library patch was made. The upstream 5,000/10,000-client profiles exceed
the application's configured connection limit.

## Memory, CPU and startup

RSS includes live children, sampled every 100 ms. HTTP peaks compare the same
completed workloads. CPU/op includes completed background work in the measurement
window, but excludes work still queued afterward.

| Measurement, median | Rust | V |
| --- | ---: | ---: |
| Idle RSS | 31.70 MiB | 17.42 MiB |
| Peak RSS during HTTP | 116.56 MiB | 49.76 MiB |
| Peak RSS in successful 500-client fan-out | 125.72 MiB | 74.97 MiB |
| Start → health, warm filesystem cache | 71.03 ms | 390.76 ms |
| CPU per room sequence | 160.55 µs | 423.29 µs |
| CPU per history operation | 163.99 µs | 88.11 µs |
| CPU per search operation | 143.01 µs | 82.74 µs |
| CPU per message write | 1,436.96 µs | 1,226.71 µs |
| Peak WAL | 39.38 MiB | 39.39 MiB |

V used **57% less peak HTTP RSS** and **46% less CPU per read-only history
operation**. Its final durable backlog was **66,070–67,950 jobs** against the
seed's deliberately failing notification endpoints. Rust's queues can drop work
when full and are not retained in SQLite. Neither timing nor queue size measures
successful notification delivery; this workload does not predict normal backlog
growth. Per-repetition job counts and WAL measurements are in the raw results.

## Upload → actual thumbnail

Separate fresh seeds, three alternating repetitions of five uploads per app,
using the original 505,420-byte `black_hole.jpg`. Rust's legacy avatar-first series
is retained separately and precedes the corrected actual-thumbnail series, so
its media pipeline is already warm. V uploads, attaches, polls, and fetches its
processed thumbnail. Both apps' thumbnails were decoded into pixels after timing.

| Measurement | Rust | V |
| --- | ---: | ---: |
| Median upload-to-thumbnail | 71.1 ms | 150.4 ms |
| Range of repetition medians | 67.9–71.8 ms | 149.4–159.6 ms |
| Actual thumbnails decoded | 15/15 | 15/15 |
| Generated thumbnail size | 84,296 bytes | 97,639 bytes |

The apps generate different derivatives.
[Isolated upload evidence](benchmarks/20261008-rust-architecture/isolated-upload/summary.json)
is kept separate from the full suite, where V recorded uploads in only two of
three repetitions after its fan-out failure stopped one repetition.

## Conditions and verification

- **144 HTTP cases / 26,327,931 logical operations**, with zero transport, status
  or content-validation errors; warmups were also validated.
- **18 mixed scenarios**, with zero errors or invalid responses. **182,717
  acknowledged HTTP/mixed writes** were audited against stored ID, room, body
  and FTS rows, including warmups.
- Rust completed **9/9** fan-out cases; V **8/9**. Full-suite failure details
  remain in the summary; a completed runner is not a passing fan-out result.
- **32 integration checks**, the V unit suite, **21 loadgen tests**, and browser
  checks passed. A separate 1,000-connection test replaced 500 peers and delivered
  all four broadcasts; it is not a saturation test.

Both apps and their client used a **1,536 MiB/no-swap** guard, proactive stop at
1,152 MiB and `memory.high=768 MiB`. The main run peaked at **778 MiB sampled**,
including client and file cache, with **2,152 memory-high events, 22,579 socket
throttles, zero OOMs and zero OOM kills**. Results therefore describe this resource
limit. The isolated upload and saturation runs had no such throttling events.
[Main guard](benchmarks/20261008-rust-architecture/resource-guard.json).

At c=16, median unaccounted host CPU per HTTP workload was roughly **69–79% of
one core** across the apps, including runner/kernel work and unrelated jobs.
Client CPU reached **184%** for V's room sequence, near its two-core limit.
Affinity does not isolate this shared host; recorded CPU and ranges accompany
the results. The [older comparison](rust-vs-v-1b4ecb9.md) used different software,
validation and host conditions, so it is not a controlled before/after speedup.

Chromium 153 / Playwright 1.63 checked both apps. V additionally passed live
Unicode, drafts/editor preservation, reconnects, room-switch races, actual
thumbnail decoding, original downloads and mobile dark layout, with no page
errors or failed local responses. [Validation evidence](validation/20261008-rust-architecture/)
and [browser details](browser-checks.md) record the scope.

## Revisions and evidence

| Component | Revision |
| --- | --- |
| Rust official production image source | `2e392fe1c839541c3cbfcf0b980ea36310a37393` |
| Vampfire recorded checkout | `f718f4ca108cf28fa4eb1d22490a2d2d2fe65c50` (application change `76a1cdb`) |
| Unmodified V main library sources | `245448b41531381f2c51826c61dec5a1b60dc85f` |
| Official portable bootstrap | `6851aaf3f9e696b30b26e406f16095b0002acaab` (reports `V 0.5.2 89371e2`) |
| Shared verification client | `8c7570427490fa7e19311b81837c63162c763494` |

V used GCC 15.2.0 and SQLite 3.53.4. The compiler is the official portable
bootstrap, **not an exact-main self-hosted compiler**; building that compiler
exceeds this machine's safe cap. [Toolchain record](toolchain.md).
Rust ran natively from the pinned official image with host glibc. Ruby was not
remeasured. Different rendering, media and job designs remain explicit.

[Reproduce](../benchmarks/reference/README.md) ·
[Versions, flags and hashes](benchmarks/20261008-rust-architecture/environment.json) ·
[JSON results and ranges](benchmarks/20261008-rust-architecture/summary.json) ·
[CSV](benchmarks/20261008-rust-architecture/http-summary.csv).
