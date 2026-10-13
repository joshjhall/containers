---
name: yaml-crate-serde-saphyr
description: YAML is serde-saphyr (pure Rust); serde_yaml forks ng/norway/bw still embed c2rust libyaml — don't "fix" RUSTSEC-2024-0449 with them
metadata:
  type: project
---

2026-10-12 (#1109): `serde_yaml` was replaced by `serde-saphyr` 1.3 across
containers-common and stibbons after RUSTSEC-2024-0449 (`unsafe-libyaml`
unmaintained) blocked every push via the whole-lockfile osv/cargo-deny gate
([[preexisting-osv-vuln-blocks-push]]). Output stayed byte-identical for every
`.igor.yml` fixture.

**Why:** the obvious drop-ins are traps — `serde_yaml_ng` depends on
`unsafe-libyaml` directly; `serde_norway` / `serde_yaml_bw` depend on
`unsafe-libyaml-norway`, the same c2rust code renamed, which only evades the
advisory's name match. `serde_yml` is pre-1.0.

**How to apply:** use `serde_saphyr::{from_str,to_string}`; it has no `Value`
type, so tests that need a generic tree parse into `serde_json::Value`. Same
session also moved luggage to `ureq` 3 (`r.into_body().into_reader()`,
`Error::StatusCode(u16)`, `Agent::config_builder().timeout_global(..)`).
