---
name: golem-reads-outside-worktree-prompt
description: "worktree golems stall on a \"Read outside the working directories\" prompt whenever they open a /opt/librarian skill file"
type: project
metadata:
  node_type: memory
  type: project
  originSessionId: f20d3756-7c11-4435-8999-907b51540891
  modified: 2026-11-01T20:08:12.377Z
---

When `permissions.blockReadsOutsideWorkingDirectories` is set in `~/.claude/settings.json`, every
worktree golem stops at a "Read outside the working directories" overlay. This happens each time it
Reads its own librarian skill docs (`/opt/librarian/plugins/workflow/skills/...`), for example
`next-issue/phase2-plan.md` or `ship-issue/pre-ship-validation.md`. The worktree is the golem's only
working directory, so `/opt/librarian` counts as outside. Auto mode doesn't bypass the prompt. Seen
3 times in the first 20 minutes of a 3-golem run on 2026-11-01.

**Why:** the golem is idle until someone answers the prompt. The pane gate-watch reports it on the
feed as a generic "Claude needs your permission".

**How to apply:** the operator approved auto-brokering for these reads (2026-11-01). Run a pane
watcher (see `.claude/tmp/librarian-read-broker.sh` from that run) that sends `4` ONLY when the
pending path is under `/opt/librarian/` and flags anything else. The gate-watch reports only the
first prompt per golem and misses repeats, and all 3 golems sat stalled ~20 min during ship-issue.
Manually: broker it by sending option `4` ("Yes, but ask again next time") with `tmux send-keys -t
golem-<N> 4 Enter`. That approves this one read and leaves the setting alone. Don't send `1`: it
permanently changes a security setting, and that is the user's call. The lasting fix is a user
decision. Either remove the setting, or add `/opt/librarian` as an additional working directory for
golems. Related: [[golem-supervised-auto-mode]], [[golem-feed-event-classification]].
