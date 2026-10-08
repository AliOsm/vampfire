# Vampfire

[Campfire](https://github.com/basecamp/once-campfire) rewritten in V with `veb`,
SQLite WAL/FTS5, a Linux WebSocket reactor, and plain HTML/CSS/JavaScript.

Rooms and private conversations, rich messages, replies, mentions, uploads,
search, live updates, profiles, invitations, bots/webhooks, and Web Push/PWA.
See the [feature and verification matrix](docs/parity.md) for coverage and gaps.

## Rust vs V

Original [Campfire Ruby/Rust benchmark workloads](benchmarks/reference/README.md),
measured **2026-10-08** after adapting the [Rust optimizations](docs/optimizations.md).
Medians of three alternating runs on an Intel i5-8500: four server cores, two
client cores, native release binaries; **V built with `-prod`, GCC/LTO**.
HTTP uses 16 concurrent clients.
Rust revision: [`2e392fe`](https://github.com/basecamp/once-campfire-rust/commit/2e392fe1c839541c3cbfcf0b980ea36310a37393).

| Metric | [Rust Campfire](https://github.com/basecamp/once-campfire-rust) | Vampfire (V) |
| --- | ---: | ---: |
| Room request sequence¹ | 21,142 ops/s | 3,208 ops/s |
| Cached history throughput, 40 messages | 20,885 ops/s | 30,011 ops/s |
| History p99 latency | 2.52 ms | 2.97 ms |
| History throughput with 10 writes/s | 16,953 ops/s | 17,622 ops/s |
| Cached search throughput, 13 matches | 23,298 ops/s | 33,089 ops/s |
| Message-write throughput | 2,082 messages/s | 926 messages/s |
| Message-write p99 latency | 20.10 ms | 54.85 ms |
| Broadcast throughput, 500 recipients | 234.8 messages/s | 252.5 messages/s |
| Fan-out to 1,000 recipients | Passed 3/3 | **Passed 2/3; unreliable** |
| Idle memory (RSS) | 31.7 MiB | 17.4 MiB |
| Peak memory during HTTP (RSS) | 116.6 MiB | 49.8 MiB |
| Server CPU per history operation | 164 µs | 88 µs |
| Start → health check | 71.0 ms | 390.8 ms |
| Upload → actual thumbnail, separate fresh seeds | 71.1 ms | 150.4 ms |

¹ Rust renders HTML in one request; V serves a shell and four JSON requests.
V leads on cached read throughput and memory; Rust leads on writes, startup,
uploads and most tail latencies. Mixed-history ranges overlap. V also failed
three isolated 1,000-client saturation runs with reactor mailbox overloads.

This compares applications with different payloads, media and job durability:
V persists jobs/retries; Rust has best-effort in-memory queues. Both shared a
memory cap with their client; reclamation and socket throttling occurred, with
**zero OOMs**. Host load and client limits also affect results.
[Full results, conditions, and raw evidence](docs/rust-vs-v.md).

Validation: 32 integration checks, V unit checks, browser checks, and 26.3 million
HTTP operations passed. The fan-out failures above remain unresolved.

## Run locally

Requires Linux x86-64, [mise](https://mise.jdx.dev), Git, GCC, curl, util-linux
(`prlimit`), a systemd user session, and Docker Compose.

```sh
git clone https://github.com/AliOsm/vampfire.git
cd vampfire
mise trust
mise install
mise run setup
mise run dev
```

In another terminal, run `mise run services`, then open **http://localhost:8088**
and create your workspace. Docker runs the Caddy development proxy; SQLite is
embedded. Direct app access: http://localhost:8080.

V libraries use unmodified main at `245448b`; the official bootstrap compiler
reports `V 0.5.2 89371e2`. See the [toolchain record](docs/toolchain.md) for the memory-cap
limitation on building an exact-main compiler.

```sh
mise run test       # HTTP/WebSocket integration checks
mise run test:v     # security helpers and Web Push cryptography
mise run bench      # bounded local smoke benchmark
```

[Reproduce the comparison](benchmarks/reference/README.md) ·
[Operations and backups](docs/operations.md) · [Bot API](docs/bots.md)

[MIT license](LICENSE) · [Third-party notices](THIRD_PARTY.md)
