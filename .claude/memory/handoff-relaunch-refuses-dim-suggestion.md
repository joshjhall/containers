---
name: handoff-relaunch-refuses-dim-suggestion
description: "golem-handoff-relaunch.sh refuses a handed-off golem whose composer shows only Claude Code's dim next-prompt suggestion; type /clear directly, then relaunch"
metadata:
  node_type: memory
  type: project
  originSessionId: 4b169ba1-136d-473b-b15c-e43b539107ff
  modified: 2026-10-26T01:16:55.357Z
---

`golem-handoff-relaunch.sh relaunch <N>` sends `/clear` through
`golem-mode-check.sh verify_text`, which refuses when `_composer_class` reports
`input` **or** `suggestion`. A golem that ends its turn on a context-budget
handoff almost always shows an inert dim suggestion (SGR 2, e.g.
`ESC[2m/workflow:golem 1328`), so `check` says `state=due` but `relaunch` prints
`NOT SENT: the composer already holds text` and the golem idles forever.
Escape does not clear it (it re-renders).

**Why:** the suggestion is not queued input — librarian #995 measured that a
typed character replaces ghost text and Enter doesn't submit it — so refusing on
`suggestion` guards a hazard that doesn't exist. Filed as joshjhall/librarian#1223
(2026-10-25, hit on golem-1328).

**How to apply:** until #1223 lands, confirm the composer holds ONLY a dim run
(`tmux capture-pane -p -e -t golem-N | tail -5` shows `\033[2m` before the
text), then `tmux send-keys -t golem-N -l '/clear'` + `Enter`, verify the
composer is empty, and re-run `golem-handoff-relaunch.sh relaunch N` so the
stamp and resume command go through the script. Never do this when the text is
NOT dim — that's real operator input.

**Second blocker — stale work registrations.** `check` can also report
`state=not-due` / `reason=golem is background, not idle` for a golem that has
handed off and is idle, because `golem-N.work.jsonl` still holds
`register` events (e.g. finished review-cycle workflows) with no matching
`complete`. Seen on golem-1463 (2026-10-25): three pre-PR cycles registered,
never completed, all long finished. Confirm the handoff via the state file
(`checkpoint.handoff_marker` set, `r_measured: null`) and the pane (idle, dim
suggestion only), then relaunch by hand: `/clear` + `/workflow:next-issue N
--level L` via send-keys. Related: [[golem-supervised-auto-mode]],
[[golem-feed-event-classification]].
