---
name: rust-tools-use-cargo-binstall
description: "rust.sh and rust-dev.sh install cargo tools via cargo binstall, not cargo install"
metadata:
  node_type: memory
  type: project
  originSessionId: 559b336a-d05a-4ec4-abcd-7b6998955151
---

`lib/features/rust.sh` and `lib/features/rust-dev.sh` install their cargo tools
with **`cargo binstall`** (prebuilt, checksum-verified binaries), not
`cargo install` (compile from source). This was the #517 fix for the CI cold
build timeout — compiling the ~20-tool suite from source exceeded 25min.

Key facts:

- `cargo-binstall` itself is bootstrapped from its prebuilt GitHub release via
  `install_github_release`, checksum pinned in `lib/checksums.json` (Tier 2,
  `CARGO_BINSTALL_VERSION`).
- Wrappers: `cargo_binstall_tool "<crate>@${VAR}"` in rust-dev.sh; a `binstall()`
  shell function in rust.sh. Both pass `--locked --no-confirm --disable-telemetry`.
- binstall auto-falls-back to `cargo install` for crates with no prebuilt binary
  (observed: taplo-cli, cargo-modules compile).
- `tests/unit/cargo-install-policy.sh` enforces `--locked` + `@${VAR}` pinning
  across BOTH verbs and the wrapper call sites — update it if you add tools.
- `CARGO_BINSTALL_VERSION` is pinned in BOTH rust.sh and rust-dev.sh and the
  policy test checks they stay in sync (like CARGO_WATCH_VERSION/MDBOOK_VERSION).

**How to apply:** when adding a rust dev tool, add a `cargo_binstall_tool` line +
a `CARGO_<TOOL>_VERSION` var, register it in `bin/check-versions.sh`, and add it
to the symlink/verify loops. Related: [[cache-mounts-not-on-install-dirs]].
