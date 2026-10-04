---
name: rust-toolchain-pin-sync
description: "Rust toolchain lives in many pins; auto-patch syncs all X.Y + X.Y.Z pins; a moved MSRV holds the PR for review"
metadata:
  node_type: memory
  type: project
  originSessionId: 649bc936-058a-4787-afd9-866270b9eb62
  modified: 2026-07-19T21:06:03.504Z
---

Rust toolchain version is pinned in ~8 places, at two granularities. The
Dockerfile `ARG RUST_VERSION` (full `X.Y.Z`) is the single source of truth.

- **Full `X.Y.Z`** (bump to exact, e.g. `1.97.1`): Dockerfile ARG,
  `.devcontainer/docker-compose.yml` RUST_VERSION, `lib/features/rust.sh`
  fallback + doc comment.
- **Minor `X.Y`** (stays minor, floats to latest patch, e.g. `1.97`):
  `FROM rust:X.Y-slim-trixie AS luggage-builder`, all CI `toolchain: "X.Y"`
  pins (ci/release-binaries/security-scan/evidence-run workflows),
  `Cargo.toml` rust-version (MSRV), `clippy.toml` msrv.

**Auto-patch now syncs every pin.** The updater's Rust arm
(`sync_rust_minor_pins` in `bin/lib/update-versions/updaters.sh`) rewrites the
X.Y pins too. Previously it deliberately skipped them "for MSRV review", which
made every minor Rust release fail `rust-version-sync` and strand the whole
auto-patch batch (2026-10-04, 1.98 -> 1.99). MSRV review now happens via the
`hold/review-required` gate: auto-patch.yml detects a moved Cargo.toml
`rust-version` and holds the PR instead of auto-merging.

`tests/unit/rust-version-sync.sh` (added in #737) now fails the build if any
pin diverges from the Dockerfile ARG — run it after any bump; it names every
straggler. `evidence-run.yml` `default: "1.95.0"` is an evidence-matrix input
data point, NOT the build toolchain — out of scope, don't bump it.

Related: [[check-versions-scrape-pins-nonexistent]], [[auto-patch-inline-checksums]].
