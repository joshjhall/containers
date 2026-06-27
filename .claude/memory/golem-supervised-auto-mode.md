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

**CORRECTION (test of #577, CC 2.1.195 — see #585):** "inherit `auto` from
`settings.local.json`" does NOT work for a worktree golem. A fresh worktree dir
is **untrusted** (`~/.claude.json` `hasTrustDialogAccepted` null for the path),
and CC does not apply a project `settings.local.json` (incl. `defaultMode`) for
an untrusted folder. A non-interactive `tmux` launch can't show the trust
dialog, so it silently falls back to `permissionMode: default` and over-prompts
on every read/edit/test. Confirmed via session transcripts: the trusted main
checkout recorded `auto`, the golem worktree recorded `default`. ALSO: the
`--auto` in `claude '/next-issue N --auto'` is a `/next-issue` SKILL flag (skip
plan mode), NOT the harness `--permission-mode auto` — the name collision is the
trap. **Fix: pass `--permission-mode auto` explicitly on launch**
(`claude --permission-mode auto '/next-issue N --auto'`), and/or seed a trust
entry for the worktree path in `worktree-new`. The `ask` deny-rules (push / PR /
merge) DID still load and gate correctly once `auto` was on — supervision
survives auto mode. See #585; plan-gating-by-effort follow-up is #586.

**How to apply:**

- Launch golems interactive in tmux, passing `--permission-mode auto`
  EXPLICITLY (do not rely on the worktree inheriting `auto` from settings —
  untrusted worktree won't, per #585).
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
