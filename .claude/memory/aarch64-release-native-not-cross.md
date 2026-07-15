---
name: aarch64-release-native-not-cross
description: "release-binaries aarch64 leg must build native (ubuntu-24.04-arm), not cross — aws-lc-sys C build needs a sysroot"
metadata:
  node_type: memory
  type: project
  originSessionId: b189f641-174d-42d2-b730-b8eea0ad36ce
---

`release-binaries.yml` originally cross-compiled the `aarch64-unknown-linux-musl`
stibbons leg from an amd64 host with `gcc-aarch64-linux-gnu` +
`CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER`. That links fine but the
**C** dependency `aws-lc-sys` (jitterentropy) compiles vendored `.c` with the
cross-gcc, which resolves the host `/usr/include` and dies on missing target
headers: `sys/types.h`, `bits/libc-header-start.h`, `asm/types.h` → exit 101.
Result: v4.19.13 shipped with **no** arm64 Linux binary (#724).

**Fix (PR #726):** build the leg on a **native `ubuntu-24.04-arm` runner** —
the proven pattern already in `evidence-run.yml`. Native ⇒ aws-lc-sys compiles
against real arm64 headers and the `*-musl` target links with `musl-gcc` from
`musl-tools`, so the cross-linker and the `CARGO_TARGET_*_LINKER` override are
both deleted. arm64 hosted runners are free on public repos.

Distinct root cause from [[evidence-run-arch-aware]] / [[dist-profile-scoping]]
(those were linker/artifact config). When a Rust target pulls a C crate
(aws-lc-sys, ring, etc.), prefer a native arch runner over cross-compiling —
cross toolchains lack the C sysroot. Same v4.19.13 run also exposed the conform
empty-range CI bug (#725, guarded in ci.yml).
