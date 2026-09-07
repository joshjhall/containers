---
name: trailing-empty-line-hides-guard
description: "A guard against empty values is unreachable if the empty value is last — $(...) strips trailing newlines, so fixture ORDER decides whether the test discriminates"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 82116046-9a19-43a2-b85b-e362598c6c7d
  modified: 2026-09-07T15:52:37.118Z
---

`$(cmd)` strips **trailing** newlines. So a `while read` fed by `<<<"$var"`
never sees a final empty line — and a guard like `[ -n "$name" ] || continue`
is **structurally unreachable** when the empty value happens to sort last.

In #919 a fixture put its nameless job (`d:` with no `name:`) last. Deleting
the guard left the suite at 9/9, so the assertion "a nameless job is not
indexed" could never fail. Moving `d` to an **interior** position made an empty
`$name` flow through the loop for real; then deleting the guard aborted the
whole suite on bash's `bad array subscript`.

Two related bash facts that ruled out the obvious "fixes":

- An empty associative-array subscript is a fatal `bad array subscript` on
  **read as well as write** — `${MAP[""]}` cannot even be spelled, so
  "assert the empty key is absent" is not expressible.
- A wrapper that short-circuits on an empty argument (`[ -n "$1" ] || return 0`)
  answers empty whether or not the inner guard exists, so asking *through* it
  proves nothing.

**Why:** this is a specific, sneaky instance of [[assertions-must-discriminate]].
The assertion, the guard, and the fixture all looked right; only fixture
*ordering* decided whether the test could fail. Reviewers caught the symptom
(non-discriminating assertion) but named a fix that bash rejects — the real
cause was one position in a fixture.

**How to apply:** when a guard rejects an empty/degenerate value, put that value
**in the middle** of the fixture, never last. Then run the standing proof:
delete the guard and confirm THAT test reddens. If it still passes, the value is
being stripped before it ever reaches the code — fix the fixture, not the
assertion. See also [[fixture-state-hides-vectors]] and
[[discriminate-rule-has-no-fixed-point-on-scaffolding]].
