---
name: workflow-js-must-be-readable-in-worktree
description: The Workflow tool refuses a scriptPath outside the session's readable tree — copy ship-issue/workflow.js into the worktree (gitignored) before invoking the review harness
metadata:
  type: feedback
---

The `Workflow` tool only accepts a `scriptPath` it returned itself or one the
session can already read. In a worktree-isolated golem session that excludes
both `/opt/librarian/plugins/workflow/skills/ship-issue/workflow.js` and any
`/tmp` copy — each is refused with *"scriptPath must be a script path this tool
returned, or a file you can already read"*.

Copy the harness into the worktree first, under the gitignored
`.claude/memory/tmp/`:

```bash
cp /opt/librarian/plugins/workflow/skills/ship-issue/workflow.js \
   .claude/memory/tmp/ship-workflow-<N>.js
```

then invoke with the **worktree-relative** path.

**Why:** the ship-issue adversarial pre-PR review is a mandatory gate, and this
refusal reads as one stray denial line — easy to mistake for "the harness isn't
available here" and skip, or to substitute a lone `dev-core:code-reviewer`
dispatch, which is one dimension of six with no judge.

**How to apply:** when `/workflow:ship-issue` reaches Step 3.5 item 6 inside a
worktree, copy-then-invoke. Also note the harness takes `diff` and `files`
**inline**, not paths — a `diffPath`/`argsFile` spelling is silently dropped by
its type guards and yields `clean: true` from a review that never ran (#567).
Related: [[golem-push-gate-under-auto]], [[ship-review-harness-provider-error]].
