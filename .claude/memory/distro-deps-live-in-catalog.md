---
name: distro-deps-live-in-catalog
description: distro-specific system packages + release-scoped deps belong in containers-db (system_package.platforms, `distro:release` selectors); luggage reads them, no Rust tables
metadata:
  type: feedback
---

Distro differences (package names, extra deps on one release) are DATA in the
containers-db catalog, not code in luggage. Since #1164 (2026-10-13):

- `system_package.platforms` maps a logical package to per-distro names.
- `Dependency.platforms` takes a `PlatformSelector`: `distro` or
  `distro:release` (e.g. `rhel:10`, used for util_linux because ubi-minimal ships
  no `su`).
- `crates/luggage/src/sysdeps.rs` resolves them (`resolve_system_deps`) into
  `ResolvedInstall.system_deps`; the old hard-coded `package_name` table is gone.
  Only `resolve_program` (dnf → microdnf fallback) stays in code.

**Why:** the user wants the DB built out as the source of truth for platform
details ("make sure we are building out the db as planned with these details").

**How to apply:** when a tool fails on a new distro/release, add the package
mapping or a release-scoped dependency in containers-db (and re-vendor), rather
than a `match distro` in luggage. A required new catalog field needs the
3-PR flow in [[cross-repo-schema-required-flip]]; drift is gated by
[[vendored-catalog-drift-gate]].
