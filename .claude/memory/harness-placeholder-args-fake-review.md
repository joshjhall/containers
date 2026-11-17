---
name: harness-placeholder-args-fake-review
description: "A placeholder string in the review harness's `diff` arg produces a vacuous clean:true that is byte-identical to a real pass"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 04584ab7-6dfe-4dcd-a63b-73e42f9517d3
  modified: 2026-11-17T05:39:52.762Z
---

The ship-issue review harness reads `args.diff` as **the authoritative bytes the
reviewers scan**. Passing a placeholder (`"SEE_WORKTREE_FILE"`, a path, a
filename) does not make it load that file — the five dimensions scan the literal
string, find nothing, and return `clean: true`. That result is
**indistinguishable from a genuine clean review** in the output, the summary
counts, and the merge gate.

Same class as the `argsFile` bug the harness docs cite (#567), reached by hand:
there is no key with a path/file variant, and `diff`/`preScan` go **inline**
whatever their size.

**Why:** the harness is the gate that authorizes an auto-merge. A fake pass here
does not fail loudly — it merges. And the tempting workaround (the diff is 22KB,
surely there's a file variant) is exactly the move that produces it.

**How to apply:** pass the real diff text inline, or **omit `diff` entirely** —
omission is supported and documented: each reviewer derives it with `git diff
origin/main...HEAD`, costing extra tool calls but reading real bytes. Omit only
after confirming the three-dot diff actually matches what you committed (on a
single-commit branch level with main, it does). Never pass a stand-in.

**Never omit `diff` when the PR is in a different repo from the cwd.** The
fallback is cwd-relative: reviewing a containers-db PR from a containers
worktree with `diff` omitted made every dimension review the *cwd branch's*
unrelated work and still return `clean: true` (#811, containers-db#456 cycle 2;
only scope-drift noticed). For a cross-repo PR, pass the diff inline — trim
mechanically generated files to one representative plus a uniformity proof —
say in `issue.title` that the cwd diff is out of scope, and treat any cycle that
ran without it as invalid rather than counting it toward convergence.

**Never hand-retype the diff either — generate it, then verify what was sent.**
Re-emitting a 300-line diff from memory drifts silently: on containers-db#598
one cycle's args carried an invented `index` hash, and the next carried a
`-` line reading the *new* code instead of the old (`Command::new("git")` →
`crate::git_command()`), so reviewers would have seen a hunk that changes
nothing. Build `diff` from `git diff origin/main...HEAD` output (e.g. JSON-encode
the file), and after launch diff the text in the run's
`agent-*.jsonl` prompt against the real diff (unescape it first). Any non-hash
mismatch → `TaskStop` the run and discard its verdict; a hash-only mismatch is
harmless.

**The same applies to the result.** The cycle result fed to
`review-engagement.sh` and `review-convergence.sh` is machine-extractable: the
Workflow task's `.output` file (path in the task-notification) is pretty-printed
JSON, so read it with `json.load(f)["result"]`. On containers-db#614 (PR #615) a
raw-text search for the unspaced `{"cycle":1` missed. I concluded the harness
had not saved its result, hand-typed one result file and tried to hand-write the
next. Auto mode refused that as undermining oversight, and the gates ran only
after the merge. If extraction fails, `json.load` the file and print its keys
before concluding a feature is missing. If the result truly can't be read, stop
before merging; don't merge with a gap note.

Related: [[assertions-must-discriminate]] — a result that passes for the wrong
reason is worse than a failure. [[degraded-review-gate-is-not-a-pass]] — a
dimension that returns no verdict is not a clean one.
