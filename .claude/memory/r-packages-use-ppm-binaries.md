---
name: r-packages-use-ppm-binaries
description: r.sh/r-dev.sh install CRAN packages from Posit PPM binaries (x86_64 only); arm64 falls back to source compile
metadata:
  node_type: memory
  type: project
  originSessionId: f22d05e4-f465-4fa3-81e7-1934fb8d66ab
---

`lib/features/r.sh` and `lib/features/r-dev.sh` install CRAN packages from
**Posit Package Manager (PPM) prebuilt binaries**, not from-source CRAN compile.
This was the #531 fix (PR #537) for the r-dev CI cold-build cost, mirroring the
rust [[rust-tools-use-cargo-binstall]] approach.

Key facts:

- Repo: `https://packagemanager.posit.co/cran/__linux__/<VERSION_CODENAME>/<snapshot>`,
  pinned via `R_PPM_SNAPSHOT` (default `2026-06-02`) → `R_PPM_REPO`.
- `R_PPM_REPO` is written into `/etc/R/Renviron.site` and read by
  `Rprofile.site` (runtime) and the inline R install scripts (build). The
  `r-*` bash helpers run `Rscript --vanilla` (skips site files), so
  `lib/features/lib/bashrc/r-env.sh` mirrors `R_PPM_REPO` into the shell env.
- **PPM only serves a binary when `HTTPUserAgent` includes the OS suffix**
  `(... x86_64 linux-gnu)`. Format used: `R/<ver> R (<ver> <platform> <arch> <os>)`.
  Without it, PPM silently serves source.
- **PPM Linux binaries are x86_64 ONLY.** On aarch64/arm64 PPM transparently
  serves source, so `install.packages()` still compiles. That is why the apt
  `-dev` build deps in r.sh/r-dev.sh are KEPT as a source-fallback safety net —
  do not strip them. The PR-tier CI cell is `debian:trixie × amd64` (#408), so
  CI gets binaries; arm dev hosts (Apple Silicon) compile locally (expected).
- Proven: emulated `linux/amd64` with gcc removed installed `jsonlite`
  (NeedsCompilation) in ~4.5s from a binary; same install on arm64 compiled.

**How to apply:** keep the apt build-deps; if adding R packages, no change
needed (they install as binaries on amd64 automatically). Related:
[[cache-mounts-not-on-install-dirs]] (why /cache/r is not cache-mounted).
