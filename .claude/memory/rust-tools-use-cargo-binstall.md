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
- `CARGO_BINSTALL_VERSION`, `CARGO_WATCH_VERSION` and `MDBOOK_VERSION` are
  pinned in BOTH rust.sh and rust-dev.sh; `test_shared_version_vars_in_sync`
  fails if they diverge.
- **Dual-pin updater trap:** an updater case that writes to `$script_path`
  rewrites only the file check-versions registered, so the first auto-patch bump
  splits the pair and goes red. PR CI can't see it (nothing is bumped yet); it was
  caught only by adversarial review (#992).

**Why:** the sync test runs on the result of a bump, not on the updater, so
a one-file updater case passes every check until the weekly sweep fires.

**How to apply:** when adding a rust dev tool, add a `cargo_binstall_tool` line +
a `CARGO_<TOOL>_VERSION` var, register it in `bin/check-versions.sh`, give it an
updater case (and an update-checksums entry if a checksum is pinned — see
[/unconsumed-default-status-fails-silently.md](/unconsumed-default-status-fails-silently.md)),
and add it to the symlink/verify loops. Before writing any updater case,
`grep -rn '<VAR>=' lib/features/`: more than one hit means the explicit
two-`sed_inplace` pattern (the `cargo-watch)` / `mdbook)` cases), never
`$script_path`. Related: [[cache-mounts-not-on-install-dirs]].
