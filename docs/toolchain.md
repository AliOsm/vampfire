# Toolchain record

Pinned on 2026-10-06. `toolchains/v.lock.json` records immutable upstream revisions:

| Component | Revision / version |
| --- | --- |
| V main (`master`) library/source checkout | `f34e871bcd41f00baf13b32dc5d70af099893ad5` |
| Official portable `vc` bootstrap snapshot | `475a2bd7ec4bed7061721816afb46580c4fe0a5b` |
| Bootstrap compiler's reported version | `V 0.5.2 02d8026` |
| Official Linux x86-64 TCC dependency bundle | `d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74` |
| SQLite amalgamation | 3.53.4; publisher SHA3-256 checked |
| Build C compiler on this machine | GCC 15.2.0 |

`mise run setup` checks out these sources and compiles the official `vc/v.c` with
GCC. The app uses the new compiler frontend, Boehm GC, current-main `veb`, SQLite,
cryptography, and WebSocket modules. The V checkout and bootstrap sources have no
local modifications. No upstream changes or pull requests were made.

The bootstrap executable is **not** a compiler rebuilt from the pinned main
commit. Two bounded attempts to self-host current main stopped proactively at
1152 MiB. Upstream `vlib/v/driver/driver.v:104` explicitly describes self-hosting as
requiring more than 4 GiB before C compilation. Disabling unrelated backends did
not make it fit. No suitable official Linux binary for this exact revision was
available in the release/artifact queries performed during development.

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
