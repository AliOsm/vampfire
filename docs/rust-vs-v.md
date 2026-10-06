# Campfire: Rust vs V

Refreshed on **2026-10-06** with unmodified V main libraries **`1b4ecb9`**, including
merged PRs [#29719](https://github.com/vlang/v/pull/29719) and
[#29722](https://github.com/vlang/v/pull/29722). Vampfire's application source is
unchanged. [Previous `f34e871` comparison](rust-vs-v-f34e871.md).

**Host CPU load was uneven and heavier during Rust runs. These results do not
establish the optimizations' speedup or a general performance ranking.** V used
less process RAM, but still failed the 500-client connection burst in all runs.

The original [Campfire Ruby/Rust workloads and seed](../benchmarks/reference/README.md)
were run three times in alternating order, with fresh storage. Intel i5-8500:
four server CPUs, two client CPUs, native release binaries, loopback HTTP/1.1
keepalive. HTTP: c=1/16/64 for 8 seconds after warmup; fan-out: 100/500/1000 clients.

## HTTP

Medians across three runs at **16 concurrent clients**. Latency is milliseconds;
percentiles are medians of each run's percentiles, not pooled percentiles.

| Workload | Rust ops/s | V ops/s | Rust p50 / p99 | V p50 / p99 |
| --- | ---: | ---: | ---: | ---: |
| Room request sequence¹ | 7,641 | 1,931 | 1.73 / 6.57 | 7.88 / 20.18 |
| Earlier 40 messages | 9,470 | 4,205 | 1.43 / 5.38 | 3.45 / 9.93 |
| Sidebar | 6,361 | 7,359 | 2.25 / 7.19 | 1.83 / 6.70 |
| Search, 13 matches | 4,715 | 5,953 | 3.05 / 8.89 | 2.16 / 8.14 |
| Persist a message | 1,490 | 1,462 | 9.58 / 28.43 | 7.37 / 78.53 |
| Avatar² | 27,853 | 19,536 | 0.46 / 3.09 | 0.57 / 4.65 |
| CSS² | 49,892 | 40,193 | 0.26 / 1.16 | 0.30 / 3.14 |
| Health | 20,216 | 51,357 | 0.62 / 3.66 | 0.19 / 2.60 |

¹ Rust renders HTML in one request. V's room operation is the shell plus four
JSON API requests, sent sequentially; its browser fetches rooms/users concurrently.
This is a server request sequence, not browser page-load time. Initial responses
were checked for identical room/history message IDs and order, and search matches.
Other data routes also return HTML versus JSON.

² CSS is Rust's 1,218-byte reset versus V's 30,105-byte full stylesheet; avatars
are 512×512 WebP versus 640×640 JPEG. Payloads and compression differ.

At 64 writers, throughput was **2,299 vs 544 messages/s**,
with p99 **70.91 vs 787.97 ms** (Rust/V).
V's 64-writer p99 ranged from 179.20 to 829.44 ms.
All **144 HTTP scenarios / 14,186,869 logical operations** completed with zero
transport/HTTP-status errors. Warmups are additional.

## WebSocket fan-out

Throughput counts messages delivered to every recipient. Paced p99 measures POST
start to the last recipient, with 30 paced messages per run.

| Recipients | Rust messages/s | V messages/s | Rust paced p99 ms | V paced p99 ms |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 491.4 | 568.8 | 9.37 | 13.75 |
| 500 | 199.3 | **Failed 3/3** | 27.93 | — |
| 1,000 | 120.6 | Skipped after failure | 43.49 | — |

Rust completed all nine cases; V completed all three 100-client cases. At 500,
470–500 clients became ready, all 500 reported failures, and no measured messages
were received. Diagnostics report “Connection reset without closing handshake.”
The cause was not instrumented or patched. V's 1,000-client and upload cases were
skipped after each failure; 1,000 clients were not separately retested on this pin.

At 100 clients, throughput ranges overlap: **Rust 473.6–929.8**, **V 326.8–819.0
messages/s**. The higher V median is not evidence of a repeatable win. Client CPU
can also limit saturation throughput. The larger 5,000/10,000-client cases from a
later published upstream run exceed V's unchanged 2,000-client configuration.

## Memory, CPU and startup

RSS sums the server and live children, sampled every 100 ms. Peaks below compare
workloads both apps completed, excluding V's aborted-suite peak as an advantage.

| Measurement, median | Rust | V |
| --- | ---: | ---: |
| Idle process RSS | 33.4 MiB | 13.1 MiB |
| Peak RSS during HTTP | 117.6 MiB | 49.6 MiB |
| Process start → health, warm filesystem cache | 80.4 ms | 348.3 ms |
| Peak RSS in successful 100-client fan-out | 118.1 MiB | 57.9 MiB |

| Server CPU per operation at 16 clients | Rust | V |
| --- | ---: | ---: |
| Room request sequence | 373 µs | 1,514 µs |
| Earlier 40 messages | 318 µs | 679 µs |
| Search | 359 µs | 525 µs |
| Persist a message | 1,129 µs | 842 µs |

CPU includes worker threads and completed media children during the measurement
window, but excludes future work in queued jobs. V ended with **43,412–47,194 jobs**
against deliberately failing notification endpoints; 8,936–9,728 had recorded
“Only standard web ports are supported.” Its WAL peaked at **1,478–2,080 MiB**,
versus Rust's **39.4 MiB**. This failing-integration workload does not establish
normal deployment backlog growth. [Queue evidence](benchmarks/20261006-main-1b4ecb9/queue-evidence.json).

## Upload → actual thumbnail

Separate fresh seeds, three alternating repetitions of five uploads per app,
using the original 505,420-byte image. The upstream client fetches the sender's
avatar as its first image; Rust's original series is retained and followed by a
corrected actual-thumbnail series. V uploads, attaches, polls and fetches its
processed thumbnail. The apps generate different derivatives.

| Measurement | Rust | V |
| --- | ---: | ---: |
| Median upload-to-thumbnail | 75.0 ms | 440.9 ms |
| Range of repetition medians | 70.4–95.3 ms | 429.3–444.8 ms |
| Successful actual-thumbnail fetches | 15/15 | 15/15 |
| Generated thumbnail size | 84,296 bytes | 54,003 bytes |

[Upload evidence](benchmarks/20261006-main-1b4ecb9/isolated-upload/summary.json).
These values are separate from the main-suite medians.

## Conditions and verification

Other Ruby/Postgres work overlapped the runs. Average external Ruby CPU below
uses 100% for one core; this difference materially favors V in timing comparisons.

| Repetition | During Rust | During V |
| ---: | ---: | ---: |
| 1 | 94.8% | 0.0% |
| 2 | 56.0% | 0.7% |
| 3 | 200.2% | 97.8% |

[Host summary](benchmarks/20261006-main-1b4ecb9/host-contention.json) ·
[Raw host samples](benchmarks/20261006-main-1b4ecb9/host-cpu.txt).

Both apps used a 1,536 MiB/no-swap guard, proactive stop at 1,152 MiB, and kernel
reclamation/throttling at 768 MiB. Main-suite peak including clients and file
cache was **780.3 MiB**, with **zero OOM or socket-throttling events**. Memory-high
reclamation/throttling events did occur. [Guard evidence](benchmarks/20261006-main-1b4ecb9/resource-guard.json).

The updated app passed 29 integration tests, five V security checks, and local
Chromium 153 browser checks: login, history, search, and live messages between
two users, including a large Unicode message. Rust's browser smoke passed too.
No JavaScript errors or failed local responses were observed.
[Validation](validation/20261006-main-1b4ecb9/) · [Browser details](browser-checks.md).

Rust remains `ccece30`; the recorded Vampfire revision is `31c9bfc`, with the same
application source hash as before the V update. Libraries are unmodified main
`1b4ecb9`, while the official bootstrap compiler still reports `02d8026`;
it is **not an exact-main self-hosted compiler**. [Toolchain limitation](toolchain.md).

[Reproduce](../benchmarks/reference/README.md) ·
[Versions and hashes](benchmarks/20261006-main-1b4ecb9/environment.json) ·
[JSON results and ranges](benchmarks/20261006-main-1b4ecb9/summary.json) ·
[CSV](benchmarks/20261006-main-1b4ecb9/http-summary.csv).

No application optimization or V source patch was made. Different rendering,
media and job designs make this an application comparison. Ruby was not remeasured.
