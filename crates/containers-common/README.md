# containers-common

Shared types and state contracts for the containers build system. Used
by `stibbons`, `igor`, and `luggage`. Not published; consumed via
workspace path.

## Modules

- `config` — `.igor.yml` schema and YAML parsing.
- `feature` — feature registry and dependency resolution.
- `generate` — content-hash based file generation tracking.
- `template` — minijinja docker-compose / env-file rendering.
- `version` — version parser and constraint comparator (this issue).

## `version` — version parser & constraint comparator

The single source of truth for parsing version strings and evaluating
version constraints. Designed to replace the ad-hoc parsing scattered
across `bin/check-versions.sh`, the future containers-db linter, the
luggage resolver, and the stibbons CLI.

### Quick usage

```rust
use containers_common::version::{Constraint, Version, VersionStyle};

// Parse a version literal — `v` and other tag prefixes are stripped.
let v = Version::parse("v1.7.0", VersionStyle::Semver)?;

// Parse a constraint and test it.
let c = Constraint::parse(">=1.5, <2", VersionStyle::Semver)?;
assert!(c.matches(&v));

// Combine constraints (used by the resolver to merge multiple
// `requires[]` on the same tool into one effective constraint).
let other = Constraint::parse(">=1.6", VersionStyle::Semver)?;
let merged = c.intersect(&other)?;
assert!(merged.matches(&v));
# Ok::<(), Box<dyn std::error::Error>>(())
```

### Grammar

| Form          | Meaning                          |
| ------------- | -------------------------------- |
| `1.95.0`      | exact match                      |
| `>=1.7.0`     | minimum                          |
| `>=1.7, <2`   | bounded range                    |
| `1.7.x`       | prefix wildcard (also `1.x`)     |
| `~1.7.0`      | patch-compatible (cargo-style)   |
| `^1.7.0`      | minor-compatible (cargo-style)   |
| `*` / `any`   | unconstrained                    |

Two-component versions (`1.7`) and one-component versions (`2`) pad
missing fields with zero, so the catalog can store partial pins.

### Prefix tolerance

Tag-style prefixes are stripped at parse time so the catalog can record
canonical strings while upstream tags ship with prefixes:

| Prefix      | Example         | Becomes  |
| ----------- | --------------- | -------- |
| `v`, `V`    | `v1.95.0`       | `1.95.0` |
| `release-`  | `release-1.0.0` | `1.0.0`  |
| `r<digit>`  | `r1.2.3`        | `1.2.3`  |

This was the bug class behind the original `v0.3.0 → 0.4.0`
prefix-drop incident — automation that compared the raw tag strings
saw a regression where there wasn't one. The test corpus locks in the
fix.

### Style modes

`VersionStyle` selects the grammar used for parsing:

- `Semver` — default; full grammar above.
- `Prefix` — same as `Semver` today; reserved for future tightening
  when the data layer wants to document "this tool's tags are
  freeform-prefixed."
- `Calver` — date-shaped versions (`2026.04.29`); ordering is
  lexicographic on dot-separated integer components.
- `Opaque` — only exact equality and `*`/`any` work; comparators (`>=`,
  ranges, wildcards) fail loudly. Safe fallback for tools whose
  versions don't fit any common grammar.

### Cross-style behavior

`Constraint::matches` returns `false` when the constraint and version
belong to different styles (a `Semver` constraint never matches a
`Calver` version). `Constraint::intersect` is stricter — combining two
constraints with different styles returns
`IntersectError::StyleMismatch`, since the data layer should never
produce that combination and a quiet `false` would mask a bug.

### Error types

`VersionError` covers parse failures (delegated `semver::Error`,
calver component errors, opaque-mode violations, wildcards in version
literals). `IntersectError::Empty` is the signal the luggage resolver
uses to render a remediation menu (issue
[#403](https://github.com/joshjhall/containers/issues/403)).

### Crate evaluation rationale

Per the issue, we evaluated three published crates before picking one:

- **`semver` 1.x** *(chosen)* — the Rust core team crate. Native
  support for cargo-style `^` and `~`, npm-style `1.x`, comma-separated
  ranges, and pre-release semantics. Already passes the cargo test
  suite. We layer prefix-stripping, opaque/calver modes, and an
  `intersect` operation on top.
- `node-semver-rs` — npm-grammar-only. Would force npm semantics on
  cargo-style ranges and split the codebase against `cargo`'s own
  behavior. Rejected.
- `pep440-rs` — PEP 440 (Python). Wrong grammar for everything we
  consume. Rejected.

Rolling our own from scratch was rejected: the cargo-style precedence
rules are subtle and reproducing them adds a class of bugs we don't
need.

### Consumer wiring (out of scope here)

This issue lands the library only. Wiring into the containers-db
validator/linter, the luggage resolver, the stibbons CLI, and
`bin/check-versions.sh` is tracked separately (see issue #416 notes
and the design memo at
[containers-db#4](https://github.com/joshjhall/containers-db/issues/4)).
