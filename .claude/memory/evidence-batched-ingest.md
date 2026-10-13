---
name: evidence-batched-ingest
description: evidence runs ingest as ONE auto-merged containers-db PR + one tracking issue per run (#1249); cells pin to the vendored catalog and skip unpublished base images
metadata:
  type: project
---

Since #1249 (2026-10-13) `evidence-run.yml` has a `collect` job: every cell
uploads a per-cell artifact `evidence-row-<tool>-<version>-<tuple>` (an envelope
`{tool,version}+row`), and `bin/ingest-evidence-batch.sh` merges all rows into one
containers-db branch `evidence/batch/<run_id>`, opens ONE PR with
`gh pr merge --auto --squash`, and `open_run_tracking_issue` files ONE issue for
failures. First verified run: 200/200 cells → db PR #397.

Each piece fixed a real incident — don't undo them:

- Per-cell PR/issue creation flooded containers-db (167 PRs + 47 issues, then
  129 + 83). Batching replaced it.
- Per-tuple artifact names collided across versions → per-cell names.
- Cells install against the VENDORED catalog (`crates/luggage/testdata/catalog`
  mounted at /catalog), not db main: a db change merged before the matching
  luggage change produced false failures ([[luggage-vendored-catalog]]).
- `EVIDENCE_PUBLISHED_CHECK` skips tuples whose base image isn't published yet:
  the matrix and the base-image publish start on the same merge (#1163).
- Cells run `luggage install ... --user runner`; root-only runs hid a run-as-user
  PATH bug on Alpine (#1165).

Matrix rules live in `bin/lib/evidence-matrix.sh` (newest patch per minor from
the floor, claimed ∩ published tuples, pending only, cap 200). Related:
[[evidence-run-arch-aware]], [[evidence-run-validates-live-against-db-main]].
