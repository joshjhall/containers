---
name: file-followups-before-teardown
description: A subagent spawned inside a golem worktree keeps that cwd; tearing the worktree down mid-run strands it
metadata:
  node_type: memory
  type: feedback
  originSessionId: d17866a9-d58e-4c31-8e2a-f5dc4867301c
  modified: 2026-10-16T05:23:12.095Z
---

A subagent dispatched while the session is inside `.worktrees/issue-N` keeps
that directory as its cwd. If the session then runs `ExitWorktree` +
`worktree-rm.sh N` before the subagent finishes, every later tool call it makes
is refused because its cwd no longer exists. On #1102, the issue-filer for the
deferred review findings failed that way, and it had to be re-dispatched from
the main checkout to file #1284.

**Why:** Phase D teardown runs right after merge. Async subagents started just
before it are still mid-flight.

**How to apply:** Either wait for the deferred-findings filer to finish before
`ExitWorktree`, or dispatch it after teardown and tell it to work from the main
checkout. Separately, have it write the issue body to a /tmp file and use `gh
issue create --body-file`; a hook misreads a `gh` heredoc as a redirect to a
tracked path. Related: [[golem-push-gate-under-auto]],
[[worktree-guard-blocks-eval-and-heredocs]].
