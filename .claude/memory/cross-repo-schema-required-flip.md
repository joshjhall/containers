---
name: cross-repo-schema-required-flip
description: Adding a REQUIRED catalog schema field needs 3 PRs (optional→consume→required); 2 PRs guarantees a red window on containers main
metadata:
  type: project
---

containers CI validates the vendored luggage catalog against containers-db's
schema at an **unpinned** ref (`.github/workflows/ci.yml`, "Checkout
containers-db" — deliberately tracks upstream default branch). So making a new
`install_methods[]`/version field **required** in containers-db `main` turns
containers `main` red for the whole gap between the two merges.

**Three PRs, not two** (used for #805 / `method_kind`, 2026-08-22):

1. containers-db — add the field **optional** + backfill every entry
2. containers — backfill the vendored catalog + consume the field in Rust
3. containers-db — flip the field to **required**

Two PRs "db first, then containers" still leaves a red window; the extra PR is
one schema line and costs nothing. This supersedes the plain "schema goes to
containers-db FIRST" rule in
[[evidence-run-validates-live-against-db-main]] for the *required* case —
that rule is still right about ordering, just insufficient on its own.

**Backfill `fixtures/_negative/` too.** `just db-validate` passes a negative
fixture when *either* ajv or validate-catalog rejects it. Each fixture exists to
prove one specific rule fires; if the required-flip makes it ALSO fail on the
missing field, the fixture keeps "passing" while the rule it guards could have
silently regressed. Verify the ajv/sem rejection split is byte-identical before
and after the flip. Same reasoning applies to
`crates/luggage/testdata/_negative/drift-*.json`, which
`tests/unit/vendored-catalog.sh` stages over the real vendored entry.

**Prove the flip bites.** Delete the field from a copy of a real entry and
confirm ajv rejects it with `must have required property`. A required-flip that
validates vacuously looks identical to one that works.

**Mechanics.** Backfill by textual line insertion after the `"name":` line, not
a json round-trip — these files use compact one-line `support_matrix` rows that
`json.dumps` reflows, burying the change in whitespace. `just db-validate`
resolves `CONTAINERS_DB` to the image's `/opt/containers-db` copy; pass
`just CONTAINERS_DB=/workspace/containers-db db-validate` (and
`CONTAINERS_DB_SRC` for the test suite — see [[vendored-catalog-drift-gate]]).
The scanner needs no change: `render_version` clones the previous version file
as its template, so a new field carries forward on its own.
