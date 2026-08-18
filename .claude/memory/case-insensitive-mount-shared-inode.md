---
name: case-insensitive-mount-shared-inode
description: "Case-shadowed git entries share one inode — git clean -fd deletes real source; fix is core.ignorecase, auto-applied by 42-workspace-fs-health.sh"
metadata:
  node_type: memory
  type: project
  originSessionId: 1d2ee9f2-91fb-4c3e-86fa-a0de57fbb891
  modified: 2026-08-18T21:11:05.164Z
---

On a case-insensitive host mount, a file tracked as `catalog.rs` can also
appear as untracked `Catalog.rs`. **They are the same inode.** Deleting the
"extra" uppercase entry deletes the real file, so `git clean -fd` on a
case-shadowed repo silently destroys tracked source. Verified by experiment,
not inference.

Root cause is `core.ignorecase` being `false`/unset while the filesystem is
case-insensitive — the state you get by cloning on a case-sensitive volume and
later moving the repo. `git init` on the same mount auto-detects `true`, which
is the tell.

**Why:** git probes case-sensitivity once at repo creation and never
re-checks. A stale `false` makes it treat each cached dentry spelling as a
distinct path.

**How to apply:** diagnose with `git config --show-origin --get core.ignorecase`
plus `detect-case-sensitivity.sh "$PWD"` (exit 1 = insensitive). Fix with
`git config core.ignorecase true` — local to `.git/config`, covers all linked
worktrees, and does not mask genuinely new files. Startup script
`lib/runtime/42-workspace-fs-health.sh` now does this automatically
(`SKIP_CASE_FIX=true` to report only, `SKIP_CASE_CHECK=true` to disable).

Related: [[stale-symlink-attrs-virtiofs]],
[[stale-repo-local-git-identity]].
