---
name: evidence-run-arch-aware
description: evidence-run.yml is arch-parameterized (hybrid native/emulated); arm64 ACTIVE since the catalog-derived matrix (#1111/#1113)
metadata:
  node_type: memory
  type: project
  originSessionId: fbf73454-3454-4b5c-8104-f120b8e4b38e
---

`.github/workflows/evidence-run.yml` was made arch-aware in #641 (PR #649). Each
matrix leg carries `arch`/`runtime`/`runner`/`rust_target`, derived from the
tuple via an `arch_plumbing` helper in the `setup` job. The **recorded** arch
still comes from the existing `Derive tuple coordinates` split — tuple stays the
single source of truth.

**Hybrid runtime**: `native` → arch-matched runner (`ubuntu-24.04-arm` for
arm64), no `docker --platform`. `emulated` → `ubuntu-latest` +
`docker/setup-qemu-action@v3` + `docker run --platform linux/<arch>`.

**Key gotcha — the mounted `luggage` binary runs INSIDE the (possibly foreign)
container**, so it must be built for the *container* arch in both modes.
Emulated arm64 on an amd64 host cross-compiles `aarch64-unknown-linux-musl`.

**arm64 is ACTIVE** (2026-10-12): the hard-coded pilot leg is gone. The
setup job derives the matrix from the catalog via `bin/lib/evidence-matrix.sh`
(newest patch per minor x claimed tuples with a base image, pending only,
capped at 200 for GitHub's 256-job limit), and #1113 published arm64 base
images for all 9 OS versions. Both arches run native (arm64 on
`ubuntu-24.04-arm`). The emulated path below still exists for dispatch.

**Latent-bug lessons from the review (caught by the pre-PR adversarial harness,
not local lint)** — these apply now that arm64 runs:

- `CARGO_TARGET_<triple>_LINKER` is read whenever cargo builds that triple,
  regardless of runner. A native arm64 runner has only `musl-tools` (→ use
  `musl-gcc`), NOT `gcc-aarch64-linux-gnu` (that's the emulated cross-linker).
  Set the linker per-arch AND per-runtime, not unconditionally.
- `actions/upload-artifact@v4` rejects two parallel matrix legs uploading under
  one name — make artifact names per-tuple (`evidence-row-${{ matrix.tuple }}`).
- `read -r A B C < <(fn)` swallows `fn`'s non-zero exit under `set -e`. Use
  `X=$(fn) || { …; exit 1; }; read … <<< "$X"` to actually abort on bad input.

Deferred (filed-or-noted): pin GitHub Actions to commit SHAs repo-wide — every
workflow here uses floating tags, so it's a consistent sweep, not a one-off.
