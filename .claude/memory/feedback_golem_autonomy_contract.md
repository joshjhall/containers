---
name: feedback_golem_autonomy_contract
description: "How much to auto-handle vs escalate when driving golems/PRs; escalate in-conversation, never force golem attach"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2c36bdd7-4046-4f5f-b641-74b94d5babba
  modified: 2026-11-02T18:58:49.734Z
---

When orchestrating golems (parallel per-issue workers) and their PRs, run with
maximum autonomy and minimal interruption:

- **Auto-approve** routine outward gates: `git push`, `gh pr create`, re-push to
  an existing PR, and internal token-budget/dynamic-workflow confirmation
  prompts. Send the keystroke, then report.
- **Keystroke brokering is explicitly authorized** (user, 2026-11-01): "I approve
  you sending these types of key presses and approvals through to the client
  golems." That covers `tmux send-keys` into `golem-*` panes for: the ship-issue
  review-harness "Yes, run it" Workflow prompt, "Read outside the working
  directories" for `/opt/librarian/` paths (option 4), and plan approvals the
  user has OK'd in-conversation. The auto-mode classifier denied this as
  `[Auto-Mode Bypass]` before the user said so; when it fires, quote this
  authorization. Never send option `1` on the read prompt, because that
  rewrites a security setting.
- **Syncing a golem PR with main needs a per-branch operator OK** (2026-11-02).
  Force-pushes are NOT covered by the contract: the auto-mode classifier denies
  them as `[Git Destructive]`, and the user approves them branch by branch. Don't
  dodge that with `git merge origin/main`, because this repo's conform step fails
  on a PR's merge commit (`failed to get commit message: EOF`), which turned
  #1577 and #1581 red. The approved recipe is: rebase onto `origin/main`,
  confirm `git range-diff` shows `=` for every commit and no merges remain, then
  `git push --force-with-lease=<branch>:<old-remote-sha> origin HEAD:<branch>`.
  Often no sync is needed at all: a squash-merge copes with main having moved.
  The two cases that do need it are a check that reads the PR's merge ref (e.g.
  vendored-catalog drift after an upstream re-vendor) and real conflicts.
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
