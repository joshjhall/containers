---
name: gate-watch-misses-repeat-prompts
description: "golem-gate-watch.sh --stream-panes silently misses many permission/plan prompts; sweep every golem pane directly each round, never trust watcher silence"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: e7bd7eee-fc72-4e33-b396-1c9178ece7dc
  modified: 2026-11-09T23:32:06.857Z
---

`golem-gate-watch.sh --stream-panes` is not a complete source of golem prompts.
In the 2026-11-08/09 four-lane run (27 PRs) it missed:

- a plan gate (#1607)
- two merge prompts (#1609, #1623)
- three post-merge cleanup prompts. golem-1584 and golem-1593 each sat stuck
  for over 30 min after their PRs merged, leaving `status/*` labels and a
  remote branch behind.
- every "Teach auto mode about your environment?" popup

It also re-reports events after each 30-min expiry and re-arm, so a burst of
`idle` events on re-arm is usually replay, not new state.

**Why:** the watcher dedups per golem and classifies by pane shape. Repeat
prompts and unfamiliar overlays fall through, and silence looks like "busy".
This generalises the librarian-read case in [[golem-reads-outside-worktree-prompt]].

**How to apply:**

- On every sweep and every monitor re-arm, read each golem pane directly:
  `tmux capture-pane -p -t golem-N`, grepping for
  `Do you want to proceed|Ready to code|Enter to select` and `esc to interrupt`.
  Act on what the panes show, not on the watcher's events.
- Before tearing down a golem whose PR merged, check that its issue's
  `status/*` labels are gone and `git ls-remote --heads origin feature/issue-N`
  is empty. Leftovers mean its cleanup prompt is still pending.
- The "Teach auto mode" popup only blocks the golem's next turn. Answering it
  changes auto-mode settings, so leave it to the operator. The auto-mode
  classifier refuses it as `[Auto-Mode Bypass]` anyway.

Related: [[golem-feed-event-classification]], [[handoff-relaunch-refuses-dim-suggestion]].
