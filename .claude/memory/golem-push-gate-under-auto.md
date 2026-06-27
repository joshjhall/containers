---
name: golem-push-gate-under-auto
description: "auto permission mode auto-approves git push/PR-create; to hard-gate outward actions add an explicit ask rule, don't rely on the mode"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2c0d7cc1-980b-4eb5-9790-7a2c5471dde5
---

`permissions.defaultMode: "auto"` runs the safety classifier, which
auto-approves routine commands **including `git push` and `gh pr create`** —
they are not treated as dangerous enough to prompt. So "run golems in auto mode
to kill read-prompt noise" and "stop and ask me before pushing" are in **direct
tension** if you try to satisfy both with the mode alone.

**What went wrong (orchestrate test, golem-518):** to silence a review
prompt-storm I selected the interactive prompt's "switch to auto mode" option.
That also removed the push gate I had promised the user — `gh pr create` then
auto-fired and opened PR #575 without sign-off. I had *told* the user "the push
will still surface under auto" — that was wrong.

**The fix — pin the outward actions with an `ask` rule** (prompts even under
auto), so noise-reduction and push-gating stop competing:

```json
{ "permissions": {
    "defaultMode": "auto",
    "ask": ["Bash(git push:*)", "Bash(gh pr create:*)", "Bash(gh pr merge:*)"]
} }
```

**How to apply:**

- When a golem (or any session) should run low-noise via `auto` but must NOT
  push/open/merge without a human, add the `ask` rules above. Do not rely on the
  mode to gate outward actions.
- This rule lives in `.claude/settings.local.json`, which is gitignored — so it
  does NOT propagate into worktrees. Copy it in (same gap as `.env` and the
  `defaultMode:auto` setting — see [[worktree-push-hooks-gitignore]], #569) and
  fold into the hydration step ([[golem-supervised-auto-mode]], #574).
- Never assert "the push will still prompt" without having verified the actual
  rule in effect.
