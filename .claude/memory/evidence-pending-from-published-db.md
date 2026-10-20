---
name: evidence-pending-from-published-db
description: "evidence matrix judges \"pending\" against published containers-db tested[], never the vendored catalog (#1319); a stale local checkout shows a fake backlog"
metadata:
  node_type: memory
  type: project
  originSessionId: da9f7e81-b42a-48e8-89b0-33208f708c87
  modified: 2026-10-19T04:36:09.663Z
---

The push-path evidence matrix (`bin/lib/evidence-matrix.sh`, wired in
`evidence-run.yml`) takes **versions + support_matrix from the vendored
catalog** but **pending-ness from published containers-db** via
`EVIDENCE_TESTED_SOURCE` (containers-db main + open same-repo
`evidence/batch/*` PRs < 24h). Unset → falls back to vendored `tested[]`
(unit tests only). Unreadable source → exit 1, never "everything pending".

**Why:** the vendored snapshot never receives `tested[]` rows (the drift gate
deliberately ignores them), so before #1325 every push re-ran the same oldest
200 cells (1.82–1.93) and 1.94+ never got evidence. After the fix one run
(containers-db #451, 123 rows, 2026-10-19) drained the whole rust backlog
including 1.99.1.

**How to apply:**

- To check what's pending, run the matrix from an **up-to-date** `origin/main`
  tree (e.g. `git archive origin/main crates/luggage/testdata/catalog
  base-images bin/lib | tar -x -C $tmp`) with
  `EVIDENCE_TESTED_SOURCE=<containers-db checkout>`. A stale local checkout
  reports old code's 323-cell fake backlog or a pending older patch (1.99.0)
  because its vendored catalog lacks the newer one. Exit 3 = nothing pending.
- "Duplicate" rows in containers-db are not an ingest bug: the dedup key
  includes `image_digest`, so a re-test on a rebuilt image is a new row by
  design. Leftover repeats from the old loop: containers-db#450.
- A permanently failing cell still re-queues every push (#1326).

Related: [[evidence-run-arch-aware]], [[vendored-catalog-drift-gate]],
[[reconcile-uses-published-evidence]].
