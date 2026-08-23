---
name: rebase-before-blaming-your-change
description: CI red in files your branch never touched? Check whether main moved before diagnosing your own diff
metadata:
  node_type: memory
  type: feedback
  originSessionId: 5a660d70-0c9f-4e56-8853-4a046932c007
  modified: 2026-08-23T14:02:15.790Z
---

When CI fails on a check whose files your branch **does not touch**, check
`origin/main` before investigating your own diff.

This repo's main moves fast — the auto-patch bot pushes releases on a schedule
(see [[fetch-before-release-bot-owns-main]]) and golems land PRs continuously.
A branch rebased an hour ago can already be behind.

**Why:** on PR #823, `Run Tests` failed on "vendored catalog matches
containers-db". The branch touched zero catalog or luggage files. `git log
origin/main` showed #822 — a luggage catalog refactor — had landed *after* the
rebase. Rebasing onto it turned all 7 checks green with no code change.

**How to apply:** on a red check, first run
`git fetch origin main && git log --oneline HEAD..origin/main` and
`git diff origin/main...HEAD --name-only | grep <the failing area>`. An empty
grep plus a non-empty log is the signature — rebase and re-run before reading
your own code.

The reverse discipline matters just as much: *"the environment did it"* is the
same shape as a real defect, and it is tempting when a fix is close. Only accept
it on **specific, named** evidence — the failing area is untouched by the diff
and main moved, or the test prints its own outage message (a rate-limit line,
say). A failure that merely moves around between runs is not environmental; it
is unexplained, which is a different thing (see [[tests-share-results-dir]]
and #821, where that distinction cost three wrong diagnoses).
