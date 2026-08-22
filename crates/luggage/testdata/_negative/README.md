# Negative fixtures for the vendored catalog check

Each file here MUST be rejected by `just db-validate-vendored`. They prove the
check has teeth — a validator that only ever sees valid input cannot tell you
whether it would catch anything (issue #815, AC2).

They are deliberately **not** part of `../catalog/`: that directory is COPY'd
into the image verbatim by the Dockerfile, so a malformed entry inside it would
ship. The recipe validates them out-of-tree instead.

Two kinds, matching the two halves of the check:

- `schema-*.json` — violate `version.schema.json`, so **ajv** rejects them.
  These need the `../../../containers-db` checkout and are skipped offline.
- `drift-*.json` — schema-**valid** but diverging from the upstream entry for
  the same `tool`+`version`. Only the drift comparison catches these, and it is
  bash + `jq` with no network, so they gate every push including the offline
  pre-push hook.

The `drift-*` cases mirror the real hand-mirroring losses #815 found in the
vendored catalog: a dropped `install_methods[].invoke.env` (which silently
relocates `CARGO_HOME`/`RUSTUP_HOME` off `/cache`) and dropped `support_matrix`
rows (which make a supported platform look unsupported).

Two staging targets, because the drift check has two comparison paths:

| Fixture                    | Staged over                     | Exercises        |
| -------------------------- | ------------------------------- | ---------------- |
| `drift-missing-invoke-env` | `tools/rust/versions/1.96.0.json` | `canonical_diff` |
| `drift-dropped-matrix-rows`| `tools/rust/versions/1.96.0.json` | `canonical_diff` |
| `drift-index-field`        | `tools/rust/index.json`         | `compare_index`  |

`compare_index` is the field-by-field path (it must tolerate the catalog-local
`available[]` / `default_version` / `minimum_recommended` while catching every
other field), so a version-file fixture alone would leave all of its branches
unproven. `drift-index-field` is the upstream index with one shared field —
`display_name` — mutated, which is exactly the "field differs" branch.
