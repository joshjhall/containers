---
name: golem-supervised-auto-mode
description: "Run orchestrate golems in auto permission mode, never headless/skip-perms; monitor via hooks + observable state, supervise via tmux attach"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2c0d7cc1-980b-4eb5-9790-7a2c5471dde5
---

When dispatching orchestrate golems (per-issue `/next-issue --auto` processes),
the launch posture should be **interactive in tmux, inheriting the repo's
default `auto` permission mode** — NOT `--dangerously-skip-permissions`, and NOT
headless `claude -p`.

**Why:** Two approaches each fail one half of the goal, and they must not be
coupled to one transport:

- `--dangerously-skip-permissions` runs unattended but gates nothing — golems
  push PRs with zero review of high-risk steps.
- Headless `claude -p --output-format stream-json` streams JSONL live (no TUI
  buffer-at-exit), which is tempting for central monitoring — but it has **no
  TTY**, so you can't attach or answer a permission prompt. It forces skip-all.
- `acceptEdits` is also wrong: it prompts on *every* bash/push → noise →
  rubber-stamping. The repo already sets `permissions.defaultMode: "auto"` in
  `.claude/settings.local.json`; `auto`'s safety classifier auto-approves routine
  calls and prompts only on the genuinely risky class. That is the noise filter.

**How to apply:**

- Launch golems interactive in tmux with NO permission flag (inherit `auto`).
- Get central status TTY-free: git commits vs `origin/main`, PR/MR state, the
  `next-issue` state files (`phase`), and `.worktrees/.status/*.json`. Do NOT
  scrape the TUI (`tmux capture-pane`/`tail -f golem.log` are blank until exit —
  the interactive TUI paints an alternate screen buffer).
- Surface "which golem is blocked" via a `Notification` hook → one central
  `feed.jsonl` (hooks fire in interactive mode).
- Intervene on demand: attach to the one flagged golem (`tmux attach -t golem-N`
  / `docker exec -it <ctr> tmux attach -t claude`), answer, detach.

This is the design captured in issue #570 (`just golems` / `just golem-attach`).
Note: the test run that produced this insight launched golems WITH
`--dangerously-skip-permissions` — that was the throwaway-test shortcut, not the
intended steady state. Related: [[parallel-automation-golem-initiative]],
[[worktree-push-hooks-gitignore]].
