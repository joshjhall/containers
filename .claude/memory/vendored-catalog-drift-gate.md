---
name: vendored-catalog-drift-gate
description: The shipped luggage catalog is drift-checked against containers-db; test-only edge cases live in a separate fixtures-catalog
metadata:
  node_type: memory
  type: project
  originSessionId: a08c0b91-6fba-4054-a6e8-e6a66349d9a8
  modified: 2026-08-22T23:29:52.813Z
---

`crates/luggage/testdata/catalog` **ships** (Dockerfile `COPY … /opt/containers-db`)
and is now held in sync with the sibling containers-db by
`bin/check-catalog-drift.sh`, wired into `just db-validate-vendored` and
`tests/unit/vendored-catalog.sh` (#815, merged 2026-08-22).

Two catalogs, and the split is load-bearing:

- `testdata/catalog/` — production. Must mirror upstream for any tool+version
  present in both. Only `available[]`, `default_version`, and
  `minimum_recommended` may differ (they describe what this copy holds).
- `testdata/fixtures-catalog/` — hermetic input for `crates/luggage/tests/cli.rs`
  only, exempt from drift. Holds the `unsupported` windows cell, the
  `rustup-init-musl` method name, and the `1.84.x` partial-version entries.
  **Never add a test-only edge case to the production copy** — put it here.

Gotchas that cost real time:

- `$CONTAINERS_DB` is already set to `/opt/containers-db` inside these dev
  containers (Dockerfile ENV) — the image's own copy of the vendored snapshot.
  Every `just db-*` recipe reads it, so a bare `just db-validate` fails or (worse)
  would compare the catalog against itself. Run as
  `CONTAINERS_DB=/workspace/containers-db just db-validate-vendored`. The unit
  test dodges the collision by reading `$CONTAINERS_DB_SRC`; CI sets that from
  its own `_containers-db` checkout.
- `luggage catalog add-version` templates from the **vendored** file, never
  upstream, and deliberately leaves `default_version` alone. So a field added
  upstream is NOT picked up by a version bump — mirror it across first, or every
  generated entry inherits the gap.
- The comparison is canonicalized (`jq -S`), not byte-exact, because this repo
  runs dprint over JSON and containers-db does not. Reformatting a freshly
  copied file is safe.
- `just db-validate` is a LOCAL wrapper — no workflow in this repo runs it. It
  wraps what containers-db's own CI does. Don't assume a CI job exists to join.

See [[luggage-vendored-catalog]] and [[luggage-installreport-field-workspace-test]].
