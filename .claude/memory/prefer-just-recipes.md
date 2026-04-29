---
name: Prefer just recipes over bare cargo/shell
description: When a justfile recipe exists for a build/test/lint/security command, invoke it instead of the underlying cargo/shell call
type: feedback
originSessionId: 3acff745-216e-4aac-89e6-a11245b6dc31
---

When the project has a `just` recipe that wraps the cargo/shell/lint
command you're about to run (`just build`, `just test-rust`,
`just lint-rust`, `just lint-docs`, `just fmt`, `just security-scan`,
`just deny`, etc.), invoke the recipe — not the bare underlying command.

**Why:** CLAUDE.md states "Prefer these over direct cargo/shell invocations
— they stay in sync with CI." Recipes encapsulate the exact flags and
toolchain that CI uses, so preflight checks done via `just` exercise the
same code path that lefthook hooks and GitHub Actions will. Bare
invocations drift from CI subtly (different feature flags, different
profiles, missing wrapper steps). Wrappers also cover broader scope —
`just fmt` runs cargo fmt + rumdl + dprint + taplo, so calling bare
`rumdl fmt <file>` skips JSON/YAML/TOML formatting that would have been
caught.

**How to apply:**

- Before running `cargo build`, `cargo test`, `cargo clippy`, `cargo fmt`,
  `cargo deny`, `rumdl check`, `rumdl fmt`, `dprint check`, `dprint fmt`,
  `taplo fmt`, `actionlint`, `hadolint`, etc., check `just --list` (or
  grep the justfile) for an existing recipe.
- Use the recipe even if it appears to be a thin wrapper — wrappers gain
  steps over time (rumdl + dprint + taplo for `just fmt`, scope filters
  for `just lint`, etc.).
- Specifically: prefer `just lint-docs` over bare `rumdl check`, and
  `just fmt` over bare `rumdl fmt <file>`. The recipe form is broader and
  matches what lefthook will run.
- Bare cargo/tool invocations are acceptable for one-shot operations that
  aren't routine (e.g., `cargo update -p <crate>` for a single dep bump,
  `cargo install` for tooling) — those don't have recipes because they're
  not pre-commit/CI checks.
- If the user asks "did you run X?", answer in terms of recipe names
  (`just test-rust`, `just lint-docs`) rather than the raw command, so
  it's clear the canonical entry point was used.

Equivalent verbal cues to watch for: "use just recipes", "shouldn't we use
just for that", "via just", "the justfile has a recipe for" — all should
push you toward the recipe form.
