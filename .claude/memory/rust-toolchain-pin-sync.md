---
name: rust-toolchain-pin-sync
description: "Rust toolchain lives in many pins; auto-patch only bumps the RUST_VERSION default, stranding the rest — sync all + guard test"
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

**The auto-patch trap:** the weekly auto-patch only bumps the `RUST_VERSION`
default, so it moves the Dockerfile ARG / luggage image / compose / rust.sh
but leaves CI `toolchain:`, Cargo MSRV, and clippy msrv stranded on the old
version — a silent half-bump (the 1.94/1.95/1.97 split #736 describes). When
finishing a rust-bump PR, always re-check the CI/MSRV pins on `main`; they may
be behind even if the Dockerfile looks done.

`tests/unit/rust-version-sync.sh` (added in #737) now fails the build if any
pin diverges from the Dockerfile ARG — run it after any bump; it names every
straggler. `evidence-run.yml` `default: "1.95.0"` is an evidence-matrix input
data point, NOT the build toolchain — out of scope, don't bump it.

Related: [[check-versions-scrape-pins-nonexistent]], [[auto-patch-inline-checksums]].
