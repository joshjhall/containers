---
name: ship-review-whole-file-scope
description: "next-issue-ship adversarial review reads whole files, so it flags pre-existing main code as findings/scope-drift"
metadata:
  node_type: memory
  type: project
  originSessionId: 1302df11-4214-41b0-8ec2-ce64a07af38b
---

The `next-issue-ship` adversarial review harness (`workflow.js` pre-pr / pr-cycle
phases) reviews the **whole changed files**, not just the PR's hunks. On a
worktree branch whose single commit sits on top of recent merges, it surfaces
findings about code from **other already-merged issues** as both "blocking" bugs
and "scope-drift" — even when `git diff origin/main...HEAD` is clean and on-topic.

**How to apply:** before resolving a review finding under `--auto`, verify it is
actually in your diff: `git diff origin/main...HEAD -- <file> | grep <pattern>`
and `git log -1 -S<token> -- <file>` + `git merge-base --is-ancestor <sha> origin/main`.
If the offending code is already an ancestor of `origin/main`, it is pre-existing —
do NOT expand the PR to fix it. File it as a separate follow-up (deferred review
finding) and note the origin in the PR body. Only diff-local findings are in scope.

Seen on #603 (worker pool PR #624): the one "blocking" finding was a real jq
`fromdateiso8601` bug in `just golems`, but from #613 already on main → filed
as #625, not fixed in the pool PR. Related: [[parallel-automation-golem-initiative]].
