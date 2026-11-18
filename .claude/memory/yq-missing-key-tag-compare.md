---
name: yq-missing-key-tag-compare
description: "yq v4 `(.missing | tag) != \"!!null\"` is TRUE for an absent key — use has() to test absence"
type: project
metadata:
  node_type: memory
  type: project
  originSessionId: 53d55af9-8e63-4691-8f29-ccd6b98a5a52
  modified: 2026-11-18T02:28:57.030Z
---

In mikefarah yq v4.54, `select((.k | tag) != "!!null")` selects a node whose
key `k` is **absent**, even though `(.k | tag)` prints `!!null` and
`== "!!null"` returns true. Binding first
(`(.k | tag) as $t | $t == "!!null"`) is wrong too.

**Why:** In #633 (PR #636), `integration_id` was documented as optional. The
gate checked it with `tag != "!!null" and tag != "!!int"`, so it rejected any
spec that left the field out. The passing tests never noticed, because the
real spec always sets the field. The bug only surfaced when a review
deferrable led to a test with the field dropped, and that test was expected to
pass.

**How to apply:** In a yq gate that allows a key to be absent, test absence
with `has("k")`, for example `select(has("k") and (.k | tag) != "!!int")`. For
every "optional" field, include a passing run with the field removed, not just
failing mutants. Related: [[assertions-must-discriminate]],
[[mutation-checks-on-scratch-copies]].
