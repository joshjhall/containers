---
name: tf-fail-assertion-indents-first-line-only
description: "tf_fail_assertion indents each ARG by 4 spaces, not each line — grepping '^    ' on failure output hides every multi-line offender after the first"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: e7bd7eee-fc72-4e33-b396-1c9178ece7dc
  modified: 2026-11-09T14:25:55.837Z
---

`tf_fail_assertion` (`tests/framework.sh`) prints `"    $1"` once per
argument. One argument that contains embedded newlines, such as a
`file:line` offender list collected into a single string, gets the 4-space
indent on its **first line only**. The lines after it start in column 0.

**Why:** On #1597 (PR #1600) golem-1597 checked a mutation run by grepping the
failure output for `^    `. Only the first offender matched, so the mutation
briefly looked missed, though the guard had caught all of them.

**How to apply:** When counting or matching failures, grep the
offender text itself (e.g. `file:line`), not the indent. If a guard must report
each offender visibly, pass each one as its own argument to `tf_fail_assertion`,
or indent the list before passing it. Related:
[[assertions-must-discriminate]], [[mutation-checks-on-scratch-copies]].
