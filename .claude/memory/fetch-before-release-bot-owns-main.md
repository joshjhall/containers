---
name: fetch-before-release-bot-owns-main
description: Always git fetch --tags before cutting a release or branching; the auto-patch bot pushes releases + version bumps to main on a schedule
metadata:
  node_type: memory
  type: feedback
  originSessionId: b1031585-3613-4aa1-ac8c-d04a49dce410
  modified: 2026-08-02T17:11:13.053Z
---

**Always `git fetch origin --tags` before branching or running
`just release-*`.** This repo has a weekly auto-patch bot that pushes its own
release commits *and* tags directly to `main`. A stale local `main` is the
default state here, not an edge case.

**Why:** on 2026-08-02 a librarian bump was branched from a stale `main` and a
patch release cut as 4.19.20 — but the bot had already published `v4.19.20`
*and* `v4.19.21`, and had already bumped librarian v0.8.1→v0.8.3 itself. The
release commit was invalid on two counts (tag collision + wrong base version),
the PR went `CONFLICTING` before CI ever ran, and the whole thing needed a
`reset --hard` + `rebase --onto origin/main` + force-push to salvage. One
`fetch` at the start would have made it a clean 4.19.22 the first time.

**How to apply:**

- Before `just release-*`: `git fetch origin --tags`, confirm `cat VERSION`
  matches `git tag --sort=-v:refname | head -1`, and check `git status -sb`
  shows no divergence. If the bot moved `main`, rebase before cutting.
- Before branching any version-bump work: same fetch. Check whether the bot
  already applied the bump (`grep` the pin) — it tracks the same versions you
  do, so your "outdated" reading from `check-versions.sh` may be stale too.
- If a PR goes `CONFLICTING` with "no checks reported", suspect a moved base
  before debugging CI — checks don't run on a conflicting branch.
- A release cut against a taken tag is unsalvageable: drop the release commit,
  rebase the substantive commit onto current `main`, and re-cut *after* merge.

Two long-standing gaps this run re-confirmed: `bin/update-versions.sh` does
**not** update the librarian default documented in
`docs/claude-code/skills-and-agents.md` or
`docs/reference/environment-variables.md` (patch by hand); and git-cliff drops
changelog entries whose commits were squashed into a release commit, since they
fall outside the tag range. Related: [[stale-base-typos-bin-igor]],
[[update-versions-script]], [[librarian-signature-verification]].
