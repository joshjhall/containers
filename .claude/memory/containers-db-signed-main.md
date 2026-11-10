---
name: containers-db-signed-main
description: "containers-db main requires signed commits + checks; every writer must create commits via the GitHub API (GitHub-signed), never git push"
type: project
metadata:
  node_type: memory
  type: project
  originSessionId: 0eb0901f-52e8-42b6-989d-27f55e443e43
  modified: 2026-11-02T15:15:46.547Z
---

Since 2026-11-02, containers-db's `Main protection` ruleset requires `ajv + Rust validate`, `MSRV
check` (strict off) and **signed commits**, with no bypass actors. Squash merges are signed by
GitHub, so PR-based history stays verified.

- Scanner: publishes via `createCommitOnBranch` on a staging branch + tree check +
  `createRef`/`updateRefs` lease (`scanner/src/publish.rs`, #527). First live run: #530, verified.
- Evidence ingest (containers `bin/ingest-evidence-batch.sh`) still pushes unsigned → its PRs are
  blocked until containers#1573.
- Open: containers-db#529 — `dedup::decide` skips an unsigned covering PR forever (what stranded #519).

**Why:** #522/#523 auto-merged in ~3s with failing CI because the old ruleset required no checks;
the signing rule closes unsigned-evidence injection.

**How to apply:** any new automation that writes to containers-db (or containers once #904 adds
signing) must use API-created commits; a local `git commit`+push will sit BLOCKED with green checks.
Related: [[signed-commit-unknown-key-is-identity]], [[luggage-vendored-catalog]].
