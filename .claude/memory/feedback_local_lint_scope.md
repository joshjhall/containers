---
name: Don't run all-files lint locally for scoped changes
description: For non-source changes (JSON/YAML/Markdown/config), skip `just lint` (which is `lefthook run pre-commit --all-files`); rely on pre-commit's per-file gate + CI for the full battery
type: feedback
originSessionId: db9a5c80-4de3-448f-9872-54a73ea8112c
---

For changes that don't touch shell scripts or Rust source, do **not** run
`just lint` (no scope) before committing — it executes
`lefthook run pre-commit --all-files`, which scans the entire repo. The
`enforce-command-prefix` and `shellcheck` hooks alone took ~640 seconds on
a one-line JSON edit (PR #450 / issue #441), even though those hooks have no
relevance to the changed file.

**Why:** User said explicitly: "i thought wed scoped these tests to avoid
running a bunch of unnecessary tests that slow down dev and lean on ci for
the full battery before merge." Local lint should be tight; CI runs the
exhaustive checks.

**How to apply:**

- For a single-file or narrow change, validate **only** that file:
  - `dprint check <path>` for JSON/YAML/Markdown
  - `taplo fmt --check <path>` for TOML
  - `cargo clippy -p <crate>` (or `just lint <scope>`) for Rust changes
    confined to one crate
  - `lefthook run pre-commit --files <path>` if you want lefthook hook
    coverage on just that file
- The `commit-msg` hook (conform) and the staged-file pre-commit hooks fire
  automatically on `git commit` — that's the natural per-file gate
- CI runs the full lint matrix on every PR — trust it
- `just lint` (no args) is a "lint everything" recipe, intended for
  pre-release sweeps or chasing down repo-wide drift, not the routine
  pre-commit step on a scoped change
