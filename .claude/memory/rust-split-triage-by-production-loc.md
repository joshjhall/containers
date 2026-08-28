---
name: rust-split-triage-by-production-loc
description: Triage Rust split candidates by production LOC (loc_engine.py), not total lines — co-located tests inflate totals and cause false split candidates
metadata:
  type: project
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

The `rs` budget (`check-decomposition/thresholds.yml` → `per_language.rs`) is
**400 warning / 700 high production LOC**. Measured on 2026-08-28:

| file | total | production LOC | verdict |
| --- | --- | --- | --- |
| `crates/stibbons/src/agent/worktree.rs` | 1600 | 437 | marginally over warning |
| `crates/stibbons/src/agent/commands.rs` | 955 | 403 | ~at warning |
| `crates/luggage/src/resolver.rs` | 958 | 271 | **well under — declined in #845** |

A quick corroboration in either direction: `check-decomposition/patterns.py`
emits **no `file-length` finding** for a file inside its budget, even when a
`decomposition-seam` row is present. A seam alone is not a reason to split — it
describes where a split *would* fall, not whether one is warranted.

**Do not extract tests to shrink a total.** `#[path = "x_tests.rs"] mod tests;`
would satisfy a line count while making the code less idiomatic; co-located
tests are standard Rust and this repo's dominant convention (~30 files). The two
files that do use `#[path]` earned it with 480–759-line suites over genuinely
large production bodies.

Note the interaction with `tests/unit/file-size-ceiling.sh`: that ratchet
measures **total** lines on purpose ("did this file grow?"), so a
declined-but-large file must **stay** in `GRANDFATHERED` — removing its entry
fails `test_no_ungrandfathered_file_over_ceiling`. Such an entry is a
measurement artifact, not tracked debt; say so in its comment.

Related: [[luggage-tooldb-design]], [[v5-architecture]]
