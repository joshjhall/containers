---
name: git-cliff-worktree-empty-changelog
description: git-cliff 2.8.0 inside a .worktrees/ checkout writes a header-only CHANGELOG unless --workdir is passed
metadata:
  node_type: memory
  type: project
  originSessionId: 04d85dd5-ea92-46b9-869e-ba83371e2dda
  modified: 2026-10-25T14:39:43.812Z
---

git-cliff 2.8.0 run from a linked worktree (`.git` is a file) resolves the
main checkout, treats the worktree path as an include filter ("Including
changes from the current directory: ../../../.worktrees/x"), matches no
commits, and writes a header-only CHANGELOG.md — every past release erased,
while `release.sh` still printed "✓ Generated CHANGELOG.md". `--workdir <root>`
fixes it; `--repository .` does not.

**Why:** hit 2026-10-25 re-cutting the failed v4.21.3 auto-patch from a
worktree; fixed in #1423 (`run_git_cliff_changelog` in
bin/lib/release/git-cliff.sh passes --workdir and refuses section-less output).

**How to apply:** if git-cliff is ever invoked outside `run_git_cliff_changelog`
(new script, CI step, manual regen), pass `--workdir`. After any release cut,
sanity-check `git diff --stat CHANGELOG.md` is mostly additions, not thousands
of deletions. Related: [[fetch-before-release-bot-owns-main]],
[[update-versions-script]].
