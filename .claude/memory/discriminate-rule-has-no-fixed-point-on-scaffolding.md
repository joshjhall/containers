---
name: discriminate-rule-has-no-fixed-point-on-scaffolding
description: Applied to test scaffolding, "assertions must discriminate" is self-feeding — each round's guards become the next round's undriven branches; break it by deleting machinery, not by driving one more layer
metadata:
  type: feedback
---

The `#900 → #903 → #907 → #913` chain on `tests/unit/features/claude-code-setup.sh`
ran the same shape four times. Each round was a correct application of
[[assertions-must-discriminate]], and each manufactured the next round's finding:

| round | fixed | created |
| --- | --- | --- |
| #900 | doc count could drift silently | 3 undriven drift branches |
| #903 | drove those 3 from a scratch fixture | the fixture helper's 2 branches |
| #907 | drove those 2 | the setup helper's 3 branches |

Test code needs guards; guards are branches; branches want tests; those tests
need guards. **The reviewer is right every round — the loop is structural, not a
quality problem.**

**The proportion is the tell.** The subject under test was one line
(`DEFAULT_PLUGINS=...`); the cluster reached ~392 lines with 20 filesystem
operations. When most findings in a review cycle are about your own fixture
plumbing rather than the subject, you are in this loop.

**Why:** the rule is owed to the BEHAVIOR UNDER TEST. Scaffolding gets `set -e`
and a fail-loud helper — not its own test suite.

**How to apply:** break the loop by **deleting the branch-generating machinery**,
not by driving one more layer of it. The usual move is replacing a
copy-and-mutate scratch fixture with **committed read-only fixtures** — no
`mktemp`/`cp`/`rm -rf`/`mkdir -p` means no failure mode for a guard to cover.
The lever that removes a whole guard layer is making the expected value a
**literal instead of a derived one**: with no derived input there is no input to
validate. Then state the depth limit in a comment at the head of the cluster, or
the next reviewer re-derives the same finding and is right to.

Note the exception: a finding on the **subject** (in #913, the scan itself)
is never barred by this limit — apply it. #913's review produced exactly one
such finding, and it was real: three branch tests asserted *contains* plus one
negative, so a false positive on either unnamed sibling doc passed all three.
Asserting the whole report by **equality** was both stronger and shorter.

See [[fixture-state-hides-vectors]], [[skips-render-as-passes]].
