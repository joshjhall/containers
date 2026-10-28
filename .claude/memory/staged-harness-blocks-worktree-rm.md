---
name: staged-harness-blocks-worktree-rm
description: "harness-stage.sh leaves .claude/tmp/harness/*.workflow.js untracked in a golem worktree, so worktree-rm.sh refuses teardown as \"uncommitted changes\""
type: project
metadata:
  node_type: memory
  type: project
  originSessionId: 643acafc-9599-49f4-aebf-f3ef2464abd7
  modified: 2026-10-28T03:51:25.531Z
---

`harness-stage.sh stage ship-issue` copies `workflow.js` into
`<worktree>/.claude/tmp/harness/`. Nothing cleans it up, and in some repos
`.claude/tmp/` isn't gitignored (seen on containers-db #490, 2026-10-27). So
`worktree-rm.sh N` refuses at golem Phase D with "has uncommitted changes".

**Why:** the copy is a byte-identical copy of the plugin's harness, not work
product, but `worktree-rm.sh` can't tell it apart from real uncommitted work.

**How to apply:** at teardown, run
`git -C .worktrees/issue-N status --short --untracked-files=all`. If the only
entry is `.claude/tmp/harness/*.workflow.js`, delete it and re-run
`worktree-rm.sh`. If anything else is listed, stop and inspect it. Related:
[[worktree-guard-blocks-eval-and-heredocs]].
