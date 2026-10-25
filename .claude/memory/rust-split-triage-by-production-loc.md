---
name: rust-split-triage-by-production-loc
description: "Triage Rust split candidates by production LOC (loc_engine.py), not total lines — co-located tests inflate totals and cause false split candidates"
metadata:
  node_type: memory
  type: project
  originSessionId: 23bf7b4b-2611-4880-9624-580517b17a71
  modified: 2026-10-23T05:02:37.201Z
---

Rank `.rs` split candidates by **production LOC**, not total lines. The #832
sweep ranked by total lines, which counts each file's co-located
`#[cfg(test)] mod tests` against its production body — so it nominated files
that are comfortably inside the budget.

Measure with the engine the audit lens actually uses:

```bash
python3 -c "
import sys; sys.path.insert(0,'/opt/librarian/plugins/review-audit/skills/check-decomposition')
from loc_engine import measure, find_units
lines = open('crates/luggage/src/resolver.rs').read().splitlines()
print(measure(lines, 'rs', find_units(lines, 'rs')))
"
```

**Use the right lens — there are two, and they differ (#695).**
`thresholds.yml` holds both, and picking the wrong one shifts the bar by 100
production LOC:

| lens | key in `thresholds.yml` | warning / high | consumed by |
| --- | --- | --- | --- |
| **audit** | `size_thresholds.production_loc` | **300 / 500** | `check-decomposition/patterns.py`, `/review-audit:codebase-audit` |
| **review** | `review_size_thresholds.per_language.rs` | **400 / 700** | `ship-issue`'s `sizing.{py,sh}`, the per-PR adversarial review |

The audit lens has **no per-language override** — `rs` gets the same 300/500 as
everything else. The review lens is deliberately looser (a per-PR gate firing at
300 LOC fires on most PRs and gets switched off) and is growth-aware via a
`git diff --numstat` sidecar, which the audit lens is not.

**A split candidate off an audit sweep is an audit-lens question — measure it
against 300/500.** Measured on 2026-08-28:

| file | total | production LOC | vs audit 300/500 |
| --- | --- | --- | --- |
| `crates/stibbons/src/agent/worktree.rs` | 1600 | 437 | over warning — **unassessed** |
| `crates/stibbons/src/agent/commands.rs` | 955 | 403 | over warning — **unassessed** |
| `crates/luggage/src/resolver.rs` | 958 | 271 | **under — declined in #845** |

Only the resolver.rs row is a settled verdict (#845). The other two rows are
measurements carried here for context, not adjudications: being over the
warning bar makes a file a genuine candidate, but each still needs its own
assessment — the same one #845 got — before anyone plans a split.

A quick corroboration in either direction: `check-decomposition/patterns.py`
emits **no `file-length` finding** for a file inside the audit budget, even when
a `decomposition-seam` row is present. A seam alone is not a reason to split —
it describes where a split *would* fall, not whether one is warranted.

**Do not extract tests to shrink a total.** `#[path = "x_tests.rs"] mod tests;`
would satisfy a line count while making the code less idiomatic; co-located
tests are standard Rust and this repo's dominant convention (~30 files). The two
files that do use `#[path]` earned it with 480–759-line suites over genuinely
large production bodies.

**Check that the production figure is real before assessing.** Both
`loc_engine.py` and the ceiling's awk port matched only the literal
`#[cfg(test)]`, so a test module gated `#[cfg(all(test, unix))]` counted as
production in full. #874's "617 production LOC, `test_excluded: 0`, single
cohesive unit" was really 45 LOC plus a 650-line test module. **`test_excluded:
0` on a file with a big `mod tests` is the tell** — read the gate attribute
before planning anything. The ceiling now accepts `cfg(all(…, test, …))`
(#874); the engine fix is joshjhall/librarian#1221 — until it lands the audit
lens still over-counts those files.

Note the interaction with `tests/unit/file-size-ceiling.sh`: since #873 that
ratchet measures **production LOC** too (500 ceiling), and `GRANDFATHERED` is
empty as of #874. An entry belongs only to a genuine offender with a tracked
issue — never to a counting artifact; fix the metric instead.

Related: [[luggage-tooldb-design]], [[v5-architecture]]
