---
name: worktree-guard-blocks-eval-and-heredocs
description: The worktree-isolation guard refuses bash it can't statically verify — the literal token `eval` (incl. `yq eval`), python heredocs, and multi-stage pipelines with loops
metadata:
  type: feedback
---

Inside a worktree-isolated session the Bash tool statically verifies each
command stays in-tree, and refuses what it cannot parse. Measured refusals in
one golem run (#881):

- **`yq eval '...' file`** — refused on the literal token `eval`, nothing to do
  with the expression. Use yq's implicit form: `yq '...' file`.
- **`python3 - <<'PY' … PY`** writing a file — "too complex to verify". Use the
  `Write` tool instead. (A python heredoc that only *edits an in-tree file it
  names* does pass — the refusal tracks parseability, not intent.)
- **`until …; do sleep; done` / `while true` poll loops**, and `Monitor` commands
  containing them — refused. Use `gh pr checks <N> --watch` piped to a
  line-buffered grep instead.
- **`cat -n file`** — refused, while plain `cat file` and `sed -n 1,60p file`
  pass.

**Why:** each refusal is a single line that scrolls past mid-run, and the
obvious reaction — assume the tool is unavailable and skip the step — silently
drops whatever gate the command served. This is the same failure shape as the
`context-budget.sh` variable-spelling refusal (#809).

**How to apply:** when a command is refused, re-spell it as plain literal
commands rather than concluding the operation is impossible. Prefer the
dedicated `Write`/`Edit` tools over shell redirects for file creation.
Related: [[golem-push-gate-under-auto]],
[[workflow-js-must-be-readable-in-worktree]].
