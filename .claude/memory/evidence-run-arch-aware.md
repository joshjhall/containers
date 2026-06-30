---
name: evidence-run-arch-aware
description: evidence-run.yml is arch-parameterized (hybrid native/emulated); arm64 leg wired but inactive pending base image
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

**arm64 is wired but INACTIVE**: the arm64 pilot leg is commented out in the
setup-job matrix because no arm64 base image is published yet
([[v5-architecture]]; base-images/ has only debian/12/amd64,
build-base-images.yml builds amd64 only). Uncomment to activate once #432/#434/

# 436 land — the evidence job body needs no change

**Latent-bug lessons from the review (caught by the pre-PR adversarial harness,
not local lint)** — all fire only when the arm64 leg activates:

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
