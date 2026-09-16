---
name: harness-placeholder-args-fake-review
description: A placeholder string in the review harness's `diff` arg produces a vacuous clean:true that is byte-identical to a real pass
metadata:
  type: feedback
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

Related: [[assertions-must-discriminate]] — a result that passes for the wrong
reason is worse than a failure. [[degraded-review-gate-is-not-a-pass]] — a
dimension that returns no verdict is not a clean one.
