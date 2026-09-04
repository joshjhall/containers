---
name: git-env-neutralization-boundary
description: fs-health clears 8 git env vars; membership decided by measurement against each probe, not by GIT_CONFIG_* name family
metadata:
  type: project
---

`lib/runtime/42-workspace-fs-health.sh` unsets inherited git environment
variables before any git runs. `git -C` does NOT protect against these — git
reads the environment first.

**Membership is decided by measurement, never by name family.** Three review
cycles on #894 each found a variable the previous by-name sweep had missed.

Cleared (each bends a probe this script makes): `GIT_DIR`, `GIT_COMMON_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE` (#886); `GIT_CONFIG`, `GIT_CONFIG_PARAMETERS`,
`GIT_CONFIG_COUNT`, `GIT_CONFIG_GLOBAL`/`_SYSTEM` (#894).

Three traps worth knowing before touching this:

- **`GIT_CONFIG` (legacy singular) diverts the WRITE too** — the script reports
  "set core.ignorecase=true" while the repo-local value stays wrong. A false
  success, not a silent no-op.
- **`GIT_CONFIG_PARAMETERS` arrives by accident.** Git sets it itself for every
  `git -c key=value` and exports it to children, so an ancestor `git -c`
  anywhere reaches the script with nobody exporting a `GIT_*` var.
- **`GIT_CONFIG_NOSYSTEM` must NOT be cleared** — it is an opt-*out*, not a
  redirect. Clearing it re-enables `/etc/gitconfig`, which this image ships.

Measured inert, deliberately not cleared: `GIT_CEILING_DIRECTORIES`,
`GIT_OBJECT_DIRECTORY`, `GIT_NAMESPACE`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
`GIT_DISCOVERY_ACROSS_FILESYSTEM`, `GIT_ATTR_NOSYSTEM`, the four pathspec
toggles.

Precedence decides severity: `GIT_CONFIG` / `GIT_CONFIG_PARAMETERS` /
`GIT_CONFIG_COUNT` beat the repo-local value (they mask an explicitly wrong
setting); `GIT_CONFIG_GLOBAL`/`_SYSTEM` lose to it (they only fill a gap).

Scope is this one script — it is the only `lib/runtime/` script that runs git
against a repo. If another starts, hoist to a shared helper rather than copying.

See [[git-env-leak-breaks-worktree-tests]] and [[fixture-state-hides-vectors]].
