---
name: negated-closing-keyword-still-closes
description: "GitHub reads \"close #N\" inside \"does not close #N\" as a closing keyword — a partial PR closes the issue anyway"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: a7b707ea-74c9-4f0a-aafa-86c6dbaff40c
  modified: 2026-11-18T02:28:56.797Z
---

GitHub's closing-keyword parser ignores negation. A PR body line like
"**Does not close #558.**" contains `close #558`, so merging the PR **closes
the issue**. Commits and the PR footer said only `Part of #558`, and the issue
still auto-closed (containers-db #622, 2026-11-17).
`gh pr view N --json closingIssuesReferences` shows the link before merge.

**Why:** a partial-delivery PR that names its issue next to any
close/fix/resolve verb silently closes work that is still outstanding, and a
successful merge hides it.

**How to apply:** in a PR that deliberately leaves an issue open, never put
`close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved` directly
before `#N`, even inside a negation. Write "#N stays open". Before merging,
check that `closingIssuesReferences` is empty. Related:
[[feedback_pr_merge_default]].
