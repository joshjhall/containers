---
name: ci-lint-fails-on-deleted-paths
description: Run Tests CI PR-lint feeds deleted paths to lefthook; file-based linters fail on a deletion-heavy PR — needs --diff-filter=d
metadata:
  node_type: memory
  type: project
  originSessionId: 6693106f-000b-4ebc-869b-50f81428e63c
---

The `Run Tests` CI job (`.github/workflows/ci.yml`) runs lefthook on PRs against
only the changed files, built from `git diff --name-only origin/$BASE_REF...HEAD`.
That list INCLUDES deleted paths. File-based linters handed a since-deleted path
(rumdl, shfmt, shellcheck) abort with `no such file or directory` /
`openBinaryFile: does not exist`, reddening the lint on files the PR removed.

**Trigger:** any deletion-heavy PR (artifact/skill removal like #611, which
deleted 183 files). The unit-test step and all container builds pass — only the
"Run linting (lefthook)" step fails. Local `lefthook run pre-commit` over a
clean tree does NOT reproduce it (the files exist locally; the bug is the
diff-list construction, surfacing only when HEAD no longer contains them).

**Fix (#611 / PR #669):** add `--diff-filter=d` to the diff that builds the lint
file list — excludes Deleted paths, keeps modified/added/renamed. One-line change
to the `pull_request` branch of the "Run linting (lefthook)" step.

**How to apply:** if a removal PR fails only `Run Tests`, check the log for
`lstat ...: no such file or directory` over deleted paths — it's this, not a real
lint violation. The fix is general (lives on main after #611). See
[[preexisting-osv-vuln-blocks-push]] for the *other* push/CI gotcha on this repo
(osv-scanner pre-push), and [[lint-couples-docs-to-templates]] for the
templates↔docs lint coupling.
