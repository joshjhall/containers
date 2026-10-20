---
name: heuristic-scanner-union-of-views
description: "a line-heuristic lint that must not miss sites should union a raw and a transformed view, not keep patching the transform"
metadata:
  node_type: memory
  type: feedback
  originSessionId: f6012525-de98-4912-b94c-a0567e36c826
  modified: 2026-10-19T04:09:16.555Z
---

In a lint guard built on a line heuristic (e.g. the `pipe_grep_q_sites` awk
scanner), never let a lossy transform (comment stripping, quote parsing) be the
only view the matcher sees. Run the raw view and the transformed view side by
side, and report the **union**.

**Why:** in #1301 / PR #1313, every patch to a per-line `strip_comment` fixed
the reported case and opened a new false negative. Over 5 pre-PR cycles and 1
post-PR cycle it hit `$(x)#y`, word state across `\` joins, and quotes opened on
an earlier line. One of those quote cases even regressed a site the old scanner
caught. Telling a comment `#` from a literal one needs a real bash parser. Once
both views ran and their results were unioned, a transform mistake could only
*add* a report, never hide one, and the loop converged in the next cycles. The
same no-fixed-point shape as
[[discriminate-rule-has-no-fixed-point-on-scaffolding]]: change the structure
rather than drive one more patch.

**How to apply:** when review keeps finding new holes in the same transform,
stop patching it. Union with the raw view and accept a few false positives, but
pin each one as a labelled fixture (`# NN flag (over-report)`). A false positive
fails the guard visibly; a false negative passes silently. After the switch,
re-check that the transform's own branches are still covered: some of its
mutants survived until fixtures were added that only the transform could catch
(see [[assertions-must-discriminate]]).

**The same holds for an allow-list of matcher prefixes (#1314, PR #1324).** The
scanner listed the prefixes it accepted (NAME=value with each quoting variant,
`command`), and each of review cycles 1–3 found one it didn't list. Swapping the
list for "any words up to a separator" closed every shape found so far. It also
made two arms dead: mutation showed they were never exercised, so they were
deleted. Even the general rule had a residue, quoted separators and greps later
inside a piped group, which a line heuristic can't see. The operator chose to
**pin those as unflagged known-miss fixtures, document them, and file a
follow-up (#1322)** instead of adding a tokenizer under the review cap. Cycle 5
then converged clean. When the reviewers keep generating new shapes, tell them
about the decision and the follow-up in the conventions digest, or they will
raise the same misses again.
