---
name: cargo-path-missing-luggage-rust
description: Why cargo is absent from non-login/shebang shells in luggage-built Rust containers, and where the fix belongs
metadata:
  type: project
---

In luggage-built Rust images, `cargo`/`rustc`/`rustup` can be **absent from every
non-login shell** (git hooks, CI lint, `bash -c`, and `just` shebang recipes),
while the real toolchain binaries exist at
`/cache/rustup/toolchains/<ver>/bin/`.

Root cause chain (observed 2026-07-19, RUST_VERSION 1.97.x devcontainer):

- rustup-init's output layer never materialized in `/cache/cargo`: `/cache/cargo/bin`
  and `/cache/cargo/env` are **absent**, and no `rustup` proxy binary exists anywhere.
  `/cache/rustup` is a persistent named volume (`containers-rustup`), so a stale
  volume + current image layer can desync — proxies (in `/cache/cargo`, NOT a volume)
  go missing.
- `lib/features/rust.sh:210-216` is meant to symlink `/usr/local/bin/{cargo,…}` but
  its guard `[ -f ${CARGO_HOME}/bin/${cmd} ]` checks the empty `/cache/cargo/bin`, so
  the loop **silently no-ops**. `add_to_system_path /cache/cargo/bin` (`:243`) also
  adds an empty dir. `/usr/local/bin/cargo` ends up not existing (not even dangling).
- luggage's own symlink step (`crates/luggage/src/installer/methods/script_installer.rs:122`,
  `install_symlinks`) links `$CARGO_HOME/bin/*` → `/usr/local/bin` and DOES include
  `rustup` — the code + catalog recipe (`containers-db/tools/rust/recipes/rustup.json`)
  both read as correct. So the bug is upstream of the symlink (proxies never present),
  not the symlink logic. Don't blind-edit the recipe.

**`just` gotcha (why PATH-prepend workarounds fail):** shebang recipes
(`#!/usr/bin/env bash`, e.g. the `lint` recipe) run in a temp script that does NOT
inherit a caller-prepended PATH — PATH head resets to the login default
(`/opt/fzf/bin`). Linewise recipes DO inherit it. So `export PATH=.../toolchains/.../bin`
before `git commit` fixes linewise but never the shebang `lint` hook → `cargo-lint`
dies `cargo: command not found`, exit 127, ~0.03s.

Durable fix must put cargo on the **base** PATH every shell sees — `/usr/local/bin`
(first on bare PATH, in `/etc/environment`). i.e. make rust.sh's symlink step fall
back to `$RUSTUP_HOME/toolchains/*/bin` when `$CARGO_HOME/bin` is empty.
