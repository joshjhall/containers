---
name: golem-teardown-untracked-scaffolding
description: "worktree-rm.sh refuses solo-golem teardown on the run's own untracked .claude/ scaffolding"
metadata:
  node_type: memory
  type: project
  originSessionId: ac92e6d1-228f-4cc5-9d9e-a798584681a0
  modified: 2026-10-19T14:23:47.324Z
---

`worktree-rm.sh N` refuses with "has uncommitted changes" on every solo
`/workflow:golem` teardown at L3–L4. It counts untracked files as uncommitted. Two
untracked files block it, and the pipeline creates both itself:
`.claude/settings.local.json`, which `worktree-new.sh` copies in, and
`.claude/tmp/harness/ship-issue.workflow.js`, which `harness-stage.sh` stages.
Seen on containers-db #404 (2026-10-16). On #453 (2026-10-19) only the
staged harness file blocked. settings.local.json was not listed, so the set
of blocking files can vary from run to run. Check the listing each time.

**Why:** this is not lost work. `git status --short` shows only `?? .claude/`.

**How to apply:** first list what is under `.claude/` and confirm it is only those
two files. Then delete them and re-run `worktree-rm.sh`. Never force-remove
without looking. Anything else untracked is real work, so stop and inspect it. This
is worth a librarian issue: teardown should ignore its own scaffolding. Related:
[[worktree-rm-blocked-by-held-build-artifacts]].
