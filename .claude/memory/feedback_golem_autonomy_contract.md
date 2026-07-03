---
name: feedback_golem_autonomy_contract
description: "How much to auto-handle vs escalate when driving golems/PRs; escalate in-conversation, never force golem attach"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2c36bdd7-4046-4f5f-b641-74b94d5babba
---

When orchestrating golems (parallel per-issue workers) and their PRs, run with
maximum autonomy and minimal interruption:

- **Auto-approve** routine outward gates: `git push`, `gh pr create`, re-push to
  an existing PR, and internal token-budget/dynamic-workflow confirmation
  prompts. Send the keystroke, then report.
- **Auto-merge + prune** any PR that is green CI + review-clean (no
  changes-requested, no conflicts): `gh pr merge <N> --squash --delete-branch`.
  No need to ask first.
- **CI failures**: triage infra-flake (buildx/setup/network → retry once with
  `gh run rerun --failed`) vs real (failing step matches the PR's changed
  files). Only escalate a REAL failure.

**Why:** the user explicitly does not want to hand-approve every push/merge —
"I shouldn't need to do this manually." Only genuine decisions warrant their
attention.

**How to apply:** Escalate ONLY for — a real (non-flake) CI failure, an
`ExitPlanMode` plan-gate (effort/medium+ issues plan-gate by design), a
dirty/conflicted merge, or a stall. Escalate as a **one-line question in the
main conversation** — do NOT make the user attach to the golem tmux session for
a simple approve/deny/merge. They connect directly ONLY when the question needs
a real back-and-forth conversation to resolve, which a command/merge approval
never does. Relatedly: [[feedback_pr_merge_default]],
[[feedback_auto_merge_consent]] (this batch-scoped standing consent overrides
the per-turn default while the batch runs), [[golem-supervised-auto-mode]],
[[golem-push-gate-under-auto]].
