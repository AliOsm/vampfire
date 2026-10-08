# Toolchain record

Updated to the latest V main available on 2026-10-08.
`toolchains/v.lock.json` records immutable upstream revisions:

| Component | Revision / version |
| --- | --- |
| V main (`master`) library/source checkout | `245448b41531381f2c51826c61dec5a1b60dc85f` |
| Official portable `vc` bootstrap snapshot | `6851aaf3f9e696b30b26e406f16095b0002acaab` |
| Bootstrap compiler's reported version | `V 0.5.2 89371e2` |
| Official Linux x86-64 TCC dependency bundle | `d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74` |
| SQLite amalgamation | 3.53.4; publisher SHA3-256 checked |
| Build C compiler on this machine | GCC 15.2.0 |

This includes the merged [reactor input borrowing](https://github.com/vlang/v/pull/29719)
and [mailbox payload reuse](https://github.com/vlang/v/pull/29722) optimizations.

`mise run setup` updates clean local toolchain checkouts to these pins and compiles
the official `vc/v.c` with GCC. It refuses to overwrite source changes and rebuilds
the bootstrap when its pinned snapshot changes. The app uses the new compiler
frontend, Boehm GC, current-main `veb`, SQLite,
cryptography, and WebSocket modules. The V checkout and bootstrap sources have no
local modifications. No upstream changes or pull requests were made.

The bootstrap executable is **not** a compiler rebuilt from the pinned main
commit. Two bounded attempts to self-host current main stopped proactively at
1152 MiB. Upstream `vlib/v/driver/driver.v:104` explicitly describes self-hosting as
requiring more than 4 GiB before C compilation. Disabling unrelated backends did
not make it fit. No suitable official Linux binary for this exact revision was
available in the release/artifact queries performed during development.

The bootstrap snapshot was also refreshed from upstream main. The earlier
self-hosting attempts used main `f34e871`; the documented memory requirement
has not changed, so those attempts were not repeated.

This is a material limitation against the requested exact-main toolchain. The
portable bootstrap successfully builds and tests the app against current-main
library sources, but those facts do not establish that an exact-main compiler
was used. The pin is reproducible rather than silently following a moving branch.

Builds separate V C generation from GCC compilation and serialize compilation.
`scripts/resource_guard.py` uses a 1536 MiB cgroup cap, disables swap, stops at
1152 MiB, and records resource events. Do not run it inside an unrelated cgroup
or remove the cap to retry the self-host build on this machine.

Each app build writes `.build/vampfire.build.json`, including compiler identity,
flags, timestamps, and source/binary SHA-256 hashes. Benchmark evidence embeds
this metadata. Raw local guard reports are retained under `.build/resource-reports`.

`mise.toml` pins Python, Node, and FFmpeg. Node is only needed for key generation
and optional formatting; there is no frontend build. `npm ci --ignore-scripts`
installs the pinned Prettier formatter before `mise run format`.
