---
name: containers-db-scanner-silent-failure
description: containers-db Catalog scanner reported success for weeks while every PR-create failed; catalog froze at rust 1.96.0
metadata:
  type: project
---

From roughly mid-2026 until 2026-10-12, every scheduled containers-db
`Catalog scanner` run went **green** while each rust scan failed:
`gh pr create` was refused ("GitHub Actions is not permitted to create or
approve pull requests"), and the fallback tracking issue failed too (no
`scanner-failure` label). Upstream reached rust 1.99.0; containers-db stayed at
1.96.0, and 106 orphaned `scan/rust/<date>` branches piled up.

Fixed 2026-10-12: repo setting "Allow GitHub Actions to create and approve
pull requests" enabled (a UI change — the PAT can't write repo settings, see
[[fine-grained-pat-lacks-admin]]), `scanner-failure` label created, and
containers-db #91 makes `scanner due`/`tool` exit non-zero when any tool
failed (per-tool isolation kept).

**Why:** a scanner that can't land its PR looks identical to "nothing new"
from the outside; the only signal was containers-db lagging upstream.

**How to apply:** if containers-db falls behind an upstream release, check the
scanner run *logs* (not its conclusion) and for piled-up `scan/*` branches.
The scanner names branches per day, so a leftover same-day branch blocks that
day's push — delete stale `scan/*` refs before a manual `scan.yml` dispatch.
Related: [[vendored-catalog-drift-gate]], [[zero-checks-is-not-green]].
