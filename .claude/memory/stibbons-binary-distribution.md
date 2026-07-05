---
name: stibbons-binary-distribution
description: How stibbons is versioned + distributed as release binaries (replaces committed Go igor)
metadata:
  node_type: memory
  type: project
  originSessionId: ee49f2aa-3bbc-4d63-a5e5-e14917ab1b7d
---

Issue #286 set up stibbons binary distribution, replacing the committed 8.5 MB
Go `bin/igor` (which nothing invoked — only lefthook excludes + docs referenced
it).

- **Version injection**: `crates/stibbons/build.rs` walks up from
  `CARGO_MANIFEST_DIR` to the repo-root `VERSION` file and emits
  `STIBBONS_VERSION` (with `rerun-if-changed`); falls back to
  `CARGO_PKG_VERSION` for standalone builds. `main.rs` uses
  `env!("STIBBONS_VERSION")` for both `#[command(version=...)]` and the banner.
  The stibbons crate's own `Cargo.toml` version (`0.1.0`) is NOT the product
  version — the `VERSION` file (product-wide) is the source of truth.
- **Size**: dedicated `[profile.dist]` = strip + thin LTO + codegen-units=1 +
  opt-level=s → ~3.1 MB binary (budget 15 MB). No `panic=abort` (keeps test
  semantics). Scoped to distribution builds only (`--profile dist`), NOT
  workspace-wide `[profile.release]` — see [[dist-profile-scoping]] (#700).
- **Release CI**: `.github/workflows/release-binaries.yml`, tag-triggered,
  native matrix over 6 triples (linux/darwin/windows × amd64/arm64). Linux
  arm64 cross-links with `gcc-aarch64-linux-gnu` +
  `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER` — same pattern as
  `evidence-run.yml`. Uploads `tar.gz`/`zip` + `.sha256` to the SAME release
  ci.yml creates (immutable-guarded, 422-skip). `workflow_dispatch` builds
  without uploading.
- **Install**: `bin/install-stibbons.sh` maps host uname→triple, downloads +
  checksum-verifies + installs the matching asset.

**Why:** the issue's stale ACs referenced `.pre-commit-config.yaml` + `cmd/igor`
`go build` — both gone (repo is on lefthook, no Go hook). Host compilation is
already covered by `cargo-lint` (pre-commit) + `cargo-test` (pre-push), so no
new build hook was added. See [[v5-architecture]], [[octarine-windows]]
(Windows targets viable since octarine beta.1 fixed Windows compilation).
