---
name: golem-feed-event-classification
description: "golem feed events classified gate|idle; BLOCKED clears via most-recent-line + TTL, no resolution hook"
metadata:
  node_type: memory
  type: project
  originSessionId: ca71e060-855c-46cf-ba07-bf006d50fb08
---

The golem Notification feed (`.worktrees/.status/feed.jsonl`, written by
`golem-notify.sh`, read by `just golems`) classifies each notification into an
`event` kind: `gate` (real permission decision) vs `idle` (transient "waiting
for your input"). Match is case-insensitive on the message and **defaults to
`gate`** (fail loud — an unknown notification surfaces rather than hiding).

**Why:** Pre-#600 every notification was logged `event:"blocked"`, so transient
between-turn idles (which fire while a sub-agent runs mid-work) showed as
phantom BLOCKED entries that never cleared.

**How to apply:** Blocks clear **without a resolution hook**. The feed is
append-only/chronological, so `just golems` takes only each golem's
most-recent line and lists it as BLOCKED only if it's a fresh `gate`. An `idle`
emitted once the golem resumes supersedes the earlier `gate`. A freshness
window `GOLEM_BLOCK_TTL` (default 3600s) drops gates left by exited golems.
Legacy `blocked` lines are honored as gates for back-compat. Both hook copies
(`.claude/hooks/` + `lib/features/templates/claude/hooks/`) must stay
byte-identical. See [[golem-supervised-auto-mode]] and
[[gh-pr-checks-json-state-uppercase]].
