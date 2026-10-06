# Vampfire

[Campfire](https://github.com/basecamp/once-campfire) rewritten in V with `veb`,
SQLite WAL/FTS5, a Linux WebSocket reactor, and plain HTML/CSS/JavaScript.

Rooms and private conversations, rich messages, replies, mentions, uploads,
search, live updates, profiles, invitations, bots/webhooks, and Web Push/PWA.
See the [feature and verification matrix](docs/parity.md) for coverage and gaps.

## Rust vs V

Original [Campfire Ruby/Rust benchmark workloads](benchmarks/reference/README.md),
measured **2026-10-06**. Medians of three alternating runs on an Intel i5-8500:
four server cores, two client cores, native release builds; HTTP at 16 clients.

| Metric | [Rust Campfire](https://github.com/basecamp/once-campfire-rust) | Vampfire (V) |
| --- | ---: | ---: |
| History throughput, 40 messages | 10,796 ops/s | 4,261 ops/s |
| Message-write throughput | 2,380 messages/s | 1,229 messages/s |
| Message-write p99 latency | 19.49 ms | 95.74 ms |
| Broadcast throughput, 100 recipients | 843.8 messages/s | 520.5 messages/s |
| Fan-out to 500 recipients | Passed 3/3 | **Failed 3/3** |
| Idle memory (RSS) | 33.2 MiB | 13.2 MiB |
| Peak memory during HTTP (RSS) | 117.1 MiB | 45.7 MiB |
| Server CPU per history operation | 332 µs | 681 µs |
| Start → health check | 116.9 ms | 326.9 ms |
| Upload → thumbnail, separate fresh-seed runs | 67.9 ms | 423.2 ms |

Rust led the main chat workloads; V used less RAM. These compare applications,
not languages: rendering and media pipelines differ, background jobs contended
for host CPU, and V accumulated notification jobs. Both used the same memory
limits. [Full results, caveats, and raw evidence](docs/rust-vs-v.md).

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

V libraries use unmodified main at `f34e871`; the official bootstrap compiler
reports `02d8026`. See the [toolchain record](docs/toolchain.md) for the memory-cap
limitation on building an exact-main compiler.

```sh
mise run test       # HTTP/WebSocket integration checks
mise run test:v     # security helpers and Web Push cryptography
mise run bench      # bounded local smoke benchmark
```

[Reproduce the comparison](benchmarks/reference/README.md) ·
[Operations and backups](docs/operations.md) · [Bot API](docs/bots.md)

[MIT license](LICENSE) · [Third-party notices](THIRD_PARTY.md)
