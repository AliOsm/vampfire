# Measured performance

Measured locally on 2026-10-06, using the final release binary.
Intel Core i5-8500 (6 cores, 3.00 GHz), Linux x86-64, GCC 15.2.0.
Exact V source/bootstrap revisions, flags, source and binary hashes, OS details,
and every repetition are in [the raw JSON](benchmarks/20261006T173418Z.json).

| Scenario | Concurrent clients | Operations/s | p50 ms | p95 ms | p99 ms | Server CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Load 40 messages | 8 | 1,611 | 4.54 | 8.46 | 11.04 | 121% |
| Search, return 40 hits | 8 | 1,338 | 5.29 | 10.70 | 14.31 | 266% |
| Persist a message | 8 | 1,140 | 2.06 | 24.78 | 43.89 | 104% |
| HTTP send → recipient WebSocket | 1 | 779 | 1.13 | 2.25 | 3.43 | 77% |

Values are medians of three repetitions, including each run's percentiles;
they are not percentiles recomputed from pooled samples. CPU is process CPU time
as a percentage of one core (200% means two cores), excluding the Python client.

- Server RSS after warmup: **32.1 MiB**; maximum sampled process peak RSS: **41.3 MiB**.
- **6,600 measured operations, zero request/delivery errors**; warmups and fixture
  creation are additional and excluded from the timing table.
- Final release build: about **198 seconds**, **1,026 MiB** peak cgroup memory.
  Integration suite: **29 scenarios in 9.28 seconds**. Five V security tests passed.
- Guard reports record **zero OOM events**; each run is isolated and cleans up
  its own process and database. See [validation evidence](validation/).

## What this measures

`mise run bench` starts a temporary app process with two users and 500 messages.
It measures real authenticated HTTP requests, FTS5 queries, SQLite writes, and
HTTP-to-WebSocket delivery to a second user. Each scenario warms up for 20
operations. History/search use 800 operations per repetition, writes use 400,
and live delivery uses 200. Database contents grow during the run.

All traffic is IPv4 loopback. HTTP requests open a new connection each time.
The Python standard-library client runs on the same shared host; its scheduling,
JSON parsing, and connection overhead are included in latency and throughput.
SQLite uses WAL with `synchronous=NORMAL`. There is no TLS, remote network, media
processing, external push provider, or bot service in these measurements.

These short runs are a reproducible application smoke benchmark, **not a capacity
limit, a soak test, or evidence of beating Rails/Rust**. The SQLite writer is
serialized; concurrent writes show a longer tail than single-sender delivery.
A deployment needs a representative workload and sustained tests before sizing.
No cross-language comparison is presented because no equivalent reference run
was performed on this hardware with this workload.
