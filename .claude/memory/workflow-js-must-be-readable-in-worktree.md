---
name: workflow-js-must-be-readable-in-worktree
description: The Workflow tool gates scriptPath on permissions.additionalDirectories — claude-setup now grants /opt/librarian (#967), so invoke the harness by its real path; the copy-into-worktree step is the fallback for pre-#967 images
metadata:
  node_type: memory
  type: feedback
---

The `Workflow` tool only accepts a `scriptPath` it returned itself or one the
session can already read — and "can already read" means listed in
`permissions.additionalDirectories`, **not** filesystem-readable.
`/opt/librarian` is world-readable and always was; the refusal —
*"scriptPath must be a script path this tool returned, or a file you can already
read"* — was a settings gap, so no `chmod`/`chown` would have fixed it.

**Fixed in #967.** `claude-setup` now merges `$LIBRARIAN_DIR` into
`permissions.additionalDirectories` on every boot (gated on the directory
existing, idempotent). On an image built with that change, invoke the harness at
its **real** path:

```text
/opt/librarian/plugins/workflow/skills/ship-issue/workflow.js
```

**Fallback for a pre-#967 image.** The grant lands at container build + boot, so
an already-running older container still refuses. There, copy the harness into
the worktree under the gitignored `.claude/memory/tmp/` and invoke by the
**worktree-relative** path:

```bash
cp /opt/librarian/plugins/workflow/skills/ship-issue/workflow.js \
   .claude/memory/tmp/ship-workflow-<N>.js
```

**Why:** the ship-issue adversarial pre-PR review is a mandatory gate, and this
refusal reads as one stray denial line — easy to mistake for "the harness isn't
available here" and skip, or to substitute a lone `dev-core:code-reviewer`
dispatch, which is one dimension of five with no judge.

**How to apply:** at `/workflow:ship-issue` Step 3.5 item 6, invoke by the real
path first; only if it is refused does your image predate #967 — rebuild, or
copy-then-invoke for that run. Also note the harness takes `diff` and `files`
**inline**, not paths — a `diffPath`/`argsFile` spelling is silently dropped by
its type guards and yields `clean: true` from a review that never ran (#567).
Related: [[golem-push-gate-under-auto]], [[ship-review-harness-provider-error]].
