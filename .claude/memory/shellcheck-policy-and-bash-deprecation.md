---
name: shellcheck-policy-and-bash-deprecation
description: Repo shellcheck enforcement level, the sub-warning noise to ignore, and the bash→luggage/igor/stibbons deprecation direction
metadata:
  type: project
---

**Enforced shellcheck bar = `--severity=warning`** (lefthook.yml:136 for `*.sh`;
:184 for actionlint `run:` blocks; justfile `v4` lint + `lint-workflows`).
Severity is CLI-only — shellcheck silently ignores a `severity=` key in
`.shellcheckrc` (the old dead `severity=info` line was removed in #1494). The rc
globally disables only `SC1090,SC1091,SC2016`. Gates run at WARNING, so
info/note-level codes (incl. SC2086) do NOT fail CI.

As of 2026-07-16 the repo is CLEAN at warning severity: **0 warning+ findings
across all 478 source shell scripts** (dirs: lib bin tests/{unit,framework,
integration} crates examples base-images .devcontainer; exclude tests/results —
3204 test-output scripts, not source). The dead-code family SC2034 (unused var)
/ SC2154 (referenced-unassigned) is fully clean; the last real instances were 4
in `lib/features/lib/claude/claude-setup` (PLUGINS_INSTALLED, PLUGIN_LIST_IS_OVERRIDE,
MCP_LIST_IS_OVERRIDE — dead clones of the LIVE SKILL_LIST_IS_OVERRIDE which IS
read at :506/:527; plus an add_args_array SC2154 false-positive through `eval`,
suppressed inline).

Sub-warning noise to IGNORE (info/note, not enforced): SC2317 (~235, unreachable
— false positive for the test-framework trap/callback pattern), SC2015 (~103,
A&&B||C), SC2086 (~50, word-split). Don't churn these.

**Direction:** bash is being DEPRECATED over time as functionality moves to the
Rust executables (luggage/igor/stibbons). So don't invest in large bash cleanups
— fix real dead code/bugs at the enforced level, but leave stylistic sub-warning
findings alone; that code is on the way out. See [[v5-architecture]].
