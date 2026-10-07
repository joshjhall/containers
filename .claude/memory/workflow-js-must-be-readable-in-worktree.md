---
name: workflow-js-must-be-readable-in-worktree
description: The Workflow tool only takes a scriptPath under cwd (or a granted dir) — stage harnesses with librarian's harness-stage.sh (v0.15.0+); the #967 /opt/librarian grant was revoked in #1035
metadata:
  node_type: memory
  type: feedback
---

The `Workflow` tool only accepts a `scriptPath` it returned itself or one the
session can already read. "Can already read" means under cwd or listed in
`permissions.additionalDirectories`. Being readable on the filesystem does not
count. `/opt/librarian` is world-readable and always was. The refusal —
*"scriptPath must be a script path this tool returned, or a file you can already
read"* — is a settings gap, so no `chmod`/`chown` fixes it.

**Current path (librarian v0.15.0+, #1035).** Run
`<workflow-plugin>/scripts/harness-stage.sh stage <id>` and pass the `path=` it
prints as the `scriptPath`. Read that line from the output; never use
`eval "$(…)"`. The script copies the harness to
`<cwd>/.claude/tmp/harness/<id>.workflow.js`, which is gitignored. The librarian
skills already do this at every call site.

**The #967 grant is gone.** #967 added `/opt/librarian` to
`additionalDirectories` so the real path would work. That allowed edits across
the whole tree. Once staging made the grant unnecessary, #1035 replaced it with a
boot-time revocation. Invoking `/opt/librarian/.../workflow.js` by its real path
is therefore refused again on purpose. Stage it instead.

**Fallback for an image pinned below librarian v0.15.0.** There is no
`harness-stage.sh` on such an image. Copy the harness under the worktree (for
example `.claude/memory/tmp/ship-workflow-<N>.js`) and invoke it by that path.

**Why:** the ship-issue adversarial pre-PR review is a mandatory gate. The
refusal shows up as one stray denial line, which is easy to read as "the harness
isn't available here". The run then skips the review, or swaps in a lone
`dev-core:code-reviewer` dispatch, which covers one dimension of five and has no
judge.

**How to apply:** at the `/workflow:ship-issue` adversarial review step, follow
its `harness-stage.sh` recipe. Also note that the harness takes `diff` and
`files` **inline**, not as paths. A `diffPath`/`argsFile` spelling is silently
dropped by its type guards and yields `clean: true` from a review that never ran
(#567). Related: [[golem-push-gate-under-auto]],
[[ship-review-harness-provider-error]].
