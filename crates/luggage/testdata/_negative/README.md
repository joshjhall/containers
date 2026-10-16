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

Three staging targets — one per comparison path, plus the live-pin gate:

| Fixture                       | Staged at                                   | Exercises        |
| ----------------------------- | ------------------------------------------- | ---------------- |
| `drift-missing-invoke-env`    | `tools/rust/versions/1.96.0.json`           | `canonical_diff` |
| `drift-dropped-matrix-rows`   | `tools/rust/versions/1.96.0.json`           | `canonical_diff` |
| `drift-index-field`           | `tools/rust/index.json`                     | `compare_index`  |
| `drift-vendored-only-non-pin` | `tools/rust/versions/<its .version>.json` (new file) | live-pin gate |

`drift-vendored-only-*` is added as a **new** version file named for its own
`.version` (`1.0.1`), which neither catalog holds and which is never the
Dockerfile's `ARG RUST_VERSION` pin. It must be rejected as "vendored-only and
not the live pin" (#1102, #1284). The recipe passes the real `--dockerfile` for
every drift fixture, so this one is rejected under the same flags the real check
runs with, not merely because no pin source was given. The test mirror refuses a
fixture whose version already exists in the vendored catalog or equals the pin.

`compare_index` is the field-by-field path (it must tolerate the catalog-local
`available[]` / `default_version` / `minimum_recommended` while catching every
other field), so a version-file fixture alone would leave all of its branches
unproven. `drift-index-field` is the upstream index with one shared field —
`display_name` — mutated, which is exactly the "field differs" branch.
