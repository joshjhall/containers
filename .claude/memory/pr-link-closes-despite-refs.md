---
name: pr-link-closes-despite-refs
description: "A PR linked to an issue closes it on merge even when every commit says `Refs #N` — check closedByPullRequestsReferences before merging a partial-delivery PR"
metadata:
  node_type: memory
  type: project
  originSessionId: 49f89089-f381-4664-abda-38c9e61f1703
  modified: 2026-10-27T18:02:46.357Z
---

Merging PR #1517 (2026-10-27) closed #1508 although every commit, the squash
body and the PR body said `Refs #1508`, never `Closes`. The close event had no
`commit_id`; `gh issue view 1508 --json closedByPullRequestsReferences` listed
`[1517]` — the issue was linked to the PR (Development sidebar / linked-PR
association), and GitHub closes linked issues on merge regardless of keywords.

**Why:** a deliberately partial delivery (#1508's "restore node + go" half was
still outstanding in containers-db#495 → #1521) silently lost its open issue —
and with it the `/workflow:next-issue` selection and the blocked-by chain.

**How to apply:** before merging a PR meant to leave its issue open, run
`gh issue view {N} --json closedByPullRequestsReferences`; if the PR is listed,
unlink it in the issue's Development sidebar first. If it already closed,
`gh issue reopen {N}` with a comment naming what remains, and reset the
`status/*` label (pr-pending → blocked/in-progress). Related:
[[feedback_pr_merge_default]].
