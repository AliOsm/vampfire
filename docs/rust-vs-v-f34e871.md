# Campfire: Rust vs V — before the V main update

Historical results using V libraries `f34e871`. See [the current comparison](rust-vs-v.md).

Rust led the main chat workloads in these runs. At 16 HTTP clients it delivered
**2.53× the history throughput** and **1.94× the message-write throughput**.
V used less process RAM and had lower median paced-broadcast latency at 100 clients,
but failed the 500-client fan-out in all three repetitions.

Measured on **2026-10-06**, using the original Ruby/Rust comparison's
[`bench/run` workloads](https://github.com/basecamp/once-campfire-rust/blob/ccece30e8e160d8c3e05bf395ee55ee35962093b/bench/run)
and seed. Three alternating repetitions; fresh storage per app/run; HTTP concurrency
1/16/64; fan-out 100/500/1000. Intel i5-8500, four pinned server CPUs and two client
CPUs, native release binaries, loopback keepalive. **Other Ruby/Postgres jobs ran
on this shared host**, especially during V repetitions 2/3. Ratios are indicative;
the [raw summary](benchmarks/20261006-reference/summary.json) includes every range.

## HTTP

Medians across three repetitions, **16 concurrent clients**. Latency is milliseconds;
percentiles are medians of each run's percentiles, not pooled percentiles.

| Workload | Rust ops/s | V ops/s | Rust p50 / p99 | V p50 / p99 |
| --- | ---: | ---: | ---: | ---: |
| Room request sequence¹ | 9,280 | 2,029 | 1.59 / 4.67 | 7.42 / 16.46 |
| Earlier 40 messages | 10,796 | 4,261 | 1.38 / 3.90 | 3.38 / 10.02 |
| Sidebar | 6,948 | 6,988 | 2.15 / 5.71 | 1.95 / 6.86 |
| Search, 13 matches | 8,910 | 5,230 | 1.63 / 4.39 | 2.61 / 9.58 |
| Persist a message | 2,380 | 1,229 | 6.25 / 19.49 | 7.76 / 95.74 |
| Avatar² | 57,875 | 15,732 | 0.25 / 0.81 | 0.58 / 5.88 |
| CSS² | 63,893 | 31,110 | 0.22 / 0.76 | 0.32 / 4.13 |
| Health | 45,771 | 52,535 | 0.32 / 1.12 | 0.18 / 2.35 |

¹ Rust renders HTML in one request. V returns the shell plus four API responses,
measured sequentially as one operation. Its browser fetches rooms/users concurrently;
this row measures server requests, not browser page-load time. Other data endpoints
also return HTML versus JSON. Response validation confirmed identical room/history
message IDs and order, and the same search matches.

² Native assets differ: Rust's first stylesheet is a **1,218-byte reset**, V's is its
**30,105-byte app stylesheet**. Avatars are 512×512 WebP versus 640×640 JPEG;
compression also differs.
These rows compare the actual apps' responses, not identical byte-serving work.

At 64 writers, median throughput was **2,330 vs 1,459 messages/s**, with p99
**45.82 vs 166.78 ms**. V's individual p99 values ranged from 163.71 to 730.11 ms.
All 144 measured HTTP scenarios completed: **17,015,755 logical operations,
zero transport/HTTP-status errors**. Warmups are additional.

## WebSocket fan-out

Throughput counts messages delivered to **every recipient**, not individual frames.
Paced p99 measures POST start to the last recipient, with 30 messages per repetition.

| Recipients | Rust messages/s | V messages/s | Rust paced p99 ms | V paced p99 ms |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 843.8 | 520.5 | 10.58 | 4.49 |
| 500 | 240.5 | **Failed 3/3** | 32.35 | No deliveries |
| 1,000 | 127.0 | Skipped after failure | 44.16 | — |

All nine Rust cases delivered every posted message. V's three 100-client cases did
too, but its paced p99 varied from **3.93 to 26.93 ms**. At 500 clients, 422–500 became
ready before disconnects, with **zero measured message receipts** in all three runs.
The harness stopped each V run before the 1,000-client and upload cases.

Separate **fresh-seed** checks reproduced V's failure at both **500 and 1,000
clients**, before paced posting began. The client recorded “Connection reset
without closing handshake”; all 500/1,000 clients reported failures and neither
case delivered measured messages. This diagnostic recorded **zero socket-throttling
and OOM events**. It reproduces the connection-burst failure independently of the
earlier HTTP backlog; the precise internal cause was not instrumented or patched.
[Follow-up evidence](benchmarks/20261006-reference/isolated-cable/settings.json)
is separate from the three-run medians.

The Rust client approached its two-core CPU limit during 1,000-client saturation.
These are tested throughputs, not established server capacity ceilings. The later
published Ruby/Rust run's 5,000/10,000-client cases exceed V's unchanged 2,000-client
configuration, so this comparison uses `bench/run`'s default sizes.

## Memory, startup and CPU

RSS includes the server and live children, sampled every 100 ms. The memory rows
below compare scenarios both apps completed; V's aborted full-suite peak is not
used as an advantage over Rust's completed suite.

| Measurement, median | Rust | V |
| --- | ---: | ---: |
| Idle process RSS | 33.2 MiB | 13.2 MiB |
| Peak RSS during HTTP | 117.1 MiB | 45.7 MiB |
| Peak RSS in successful 100-client fan-out | 118.1 MiB | 53.8 MiB |
| Process start → `/up`, warm filesystem cache | 116.9 ms | 326.9 ms |

| Server CPU per operation at 16 clients | Rust | V |
| --- | ---: | ---: |
| Room request sequence | 382 µs | 1,517 µs |
| Earlier 40 messages | 332 µs | 681 µs |
| Search | 360 µs | 507 µs |
| Persist a message | 1,237 µs | 857 µs |

CPU includes worker threads and completed media children during the measurement
window. It excludes the future cost of unfinished background jobs. Raw results
also include server/client CPU percentages; 100% represents one core.

V finished with **43,306–49,081 queued jobs**. Sampled notification attempts failed
against the original seed's closed-port endpoints with “Only standard web ports
are supported.” Some jobs had retried; 34,343–41,312 had no attempt yet. Its SQLite
WAL peaked at **682–2,289 MiB**, compared with Rust's roughly **39 MiB**. This is a
finding about this failing-integration workload, not a claim that all deployments
will accumulate the same backlog. See [queue evidence](benchmarks/20261006-reference/queue-evidence.json).

## Upload → actual thumbnail

The upstream client fetches the **first image in the message response: the sender's
avatar**. We retained that metric and added a separate Rust series selecting the
uploaded image's representation. V uploads, attaches, polls readiness and fetches
the processed thumbnail.

Since the main V runs stopped before uploading, this comparison uses **separate
fresh seeds**, three alternating repetitions of five uploads each, using the
original 505,420-byte `black_hole.jpg`.

| Measurement | Rust | V |
| --- | ---: | ---: |
| Median upload-to-thumbnail | **67.9 ms** | **423.2 ms** |
| Range of repetition medians | 66.8–68.3 ms | 414.0–426.4 ms |
| Successful actual-thumbnail fetches | 15/15 | 15/15 |
| Generated thumbnail size | 84,296 bytes | 54,003 bytes |

Rust's original five-upload series precedes its corrected series, warming its media
code. The apps also produce different derivatives, so this measures their native
upload workflows. These numbers are separate from the main-suite medians; the main
Rust corrected-thumbnail median was 74.1 ms. [Isolated upload evidence](benchmarks/20261006-reference/isolated-upload/summary.json).

Browser smoke checks passed for both apps using Chromium 151/Playwright 1.62.1
after the T3 preview host reported it was unavailable. Checked sign-in, 40 rendered
room messages, earlier history (Rust's fragment route; V's button loaded 80 total),
and 13 search matches. Screenshots were inspected; neither app produced JavaScript
errors or failed local responses. [Rust evidence](benchmarks/20261006-reference/browser/rust.json)
· [V evidence](benchmarks/20261006-reference/browser/vampfire.json).

## Reproduce and interpret

Use [the benchmark instructions](../benchmarks/reference/README.md). They document
the protocol adapter, original seed, immutable official Rust image, HTTP/WS settings,
upload correction and follow-ups. [CSV](benchmarks/20261006-reference/http-summary.csv)
and [JSON evidence](benchmarks/20261006-reference/summary.json) include all concurrency
levels, p50/p90/p99, CPU, bytes, error counts and individual runs.

Both apps ran within the same **1,536 MiB hard cap**, no swap, with an early stop
at 1,152 MiB and kernel reclamation/throttling at 768 MiB. The primary series peaked
at **771.4 MiB across server, client and file cache**, with **zero OOM events**.
The guard recorded memory-pressure and socket-throttling events; these constrained
results should not be extrapolated to an unrestricted production host.
[Guard evidence](benchmarks/20261006-reference/resource-guard.json) and
[observed host activity](benchmarks/20261006-reference/host-cpu.jsonl) are retained.
Two preliminary cache/log-related safety stops are [recorded separately](benchmarks/20261006-reference/preliminary-stops.json)
and excluded from the final medians.

Application sources/binaries and upstream V were unchanged for this comparison.
Rust is `ccece30`; V application `0f6ce42` uses main libraries `f34e871` with the
official bootstrap compiler reporting `02d8026`, **not an exact-main self-hosted
compiler**. See [versions/hashes](benchmarks/20261006-reference/environment.json)
and the existing [toolchain limitation](toolchain.md). Different rendering,
media pipelines, subscriptions and queue designs make this an **application
comparison, not a language-only benchmark**. Ruby was not remeasured here.
