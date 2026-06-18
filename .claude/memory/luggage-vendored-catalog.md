---
name: luggage-vendored-catalog
description: "Image builds read the VENDORED luggage catalog snapshot, not the sibling containers-db repo"
metadata:
  node_type: memory
  type: reference
  originSessionId: 1b5e3f41-0926-4163-8595-760cdaa39830
---

The image build resolves tool installs via `luggage install <tool>@<ver>`
against a **vendored catalog snapshot** at
`crates/luggage/testdata/catalog`, which the Dockerfile `COPY`s to
`/opt/containers-db` (`Dockerfile:152`, `ENV CONTAINERS_DB=/opt/containers-db`).
It does **not** read the sibling `containers-db` repo at build time.

Consequence: to make a new tool version installable in builds (e.g. when the
auto-patch bumps `RUST_VERSION` to a version luggage must resolve), you must
add it to the **vendored** catalog — `tools/<tool>/versions/<v>.json` plus the
`available` list in `tools/<tool>/index.json`. Fixing only the sibling
`containers-db` repo does NOT fix the build.

Gotchas:

- `tools/rust/index.json` `default_version` is asserted by `cli.rs` golden
  tests — keep version additions purely additive (don't bump default) unless
  you also update those tests.
- `check-versions.sh` tracks tool versions from upstream (e.g. Rust GitHub
  releases) with no awareness of the catalog, so the pin can outrun the
  snapshot and break the build. See [[luggage-tooldb-design]].

The Dockerfile comment notes a real containers-db checkout will replace the
vendored snapshot "once that workflow lands" — until then, the vendored copy
is authoritative for builds.
