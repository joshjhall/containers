---
name: rust-toolchain-pin-sync
description: "Rust pins split into a frozen build chain (MSRV, deliberate PR) and a container default (auto-patch, no hold) since #1111"
metadata:
  node_type: memory
  type: project
  originSessionId: 649bc936-058a-4787-afd9-866270b9eb62
  modified: 2026-10-12T21:30:00.000Z
---

Since #1111 (2026-10-12) Rust is pinned in **two independent roles**; see
`docs/reference/rust-version-policy.md`.

- **Build chain = MSRV, X.Y, frozen** (1.99, held ≥6 months): `Cargo.toml`
  rust-version (source of truth), `clippy.toml` msrv, every CI
  `toolchain: "X.Y"`, `FROM rust:X.Y-slim-trixie AS luggage-builder`. Moved
  only by a deliberate PR. auto-patch.yml now **fails** if an auto-patch edits
  rust-version/msrv.
- **Container default, X.Y.Z, follows latest**: Dockerfile `ARG RUST_VERSION`
  (source of truth), `lib/features/rust.sh` fallback,
  `.devcontainer/docker-compose.yml` RUST_VERSION, plus the vendored catalog.
  The updater's Rust arm bumps only these; no review hold.

`tests/unit/rust-version-sync.sh` enforces each group against its own source
of truth plus one link: default >= MSRV. Bumping the MSRV: edit
`rust-version`, run the test, it names every build-chain straggler.

**Why:** before #1111, `sync_rust_minor_pins` dragged every X.Y pin (MSRV
included) along with each minor Rust release and auto-patch held the PR for
review (#1110), so a forced MSRV raise needed human approval every ~6 weeks.
`rust-pins.sh` is deleted. A non-blocking `rust-latest-stable` CI job (clippy
on floating stable) surfaces new lints before a deliberate MSRV bump.

`evidence-run.yml` `default: "1.95.0"` is an evidence-matrix data point, not
the build toolchain.

Related: [[check-versions-scrape-pins-nonexistent]], [[auto-patch-inline-checksums]].
