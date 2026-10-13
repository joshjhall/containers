---
name: reconcile-uses-published-evidence
description: luggage reconcile fetches tested[] from published containers-db; unreachable → stale-evidence warning with newest tested_at, never a gate failure
metadata:
  type: project
---

Since #1108 (2026-10-12) `luggage reconcile` refreshes each version's
`tested[]` from published containers-db (`--published-base`, default raw
`main`) before judging `support_matrix` claims. Origins: `published` and
`not yet published` (HTTP 404 = authoritative) are judged normally and gate;
`fallback` (network error, 5xx, unparsable/misrouted body, or `--offline`)
uses the local rows and reports **stale-evidence warnings** naming the newest
local `tested_at` — never gate failures.

**Why:** the user's rule — check the latest published data before reporting a
problem; if it can't be reached (offline/air-gapped), stale evidence may be
acceptable, so warn with its age rather than block. This is what let the drift
gate stop comparing `tested[]` ([[vendored-catalog-drift-gate]]).

**How to apply:** keep "unreachable" and "not found" distinct in any evidence
fetch — the installer's `HttpClient` folds them into one error, which is why
`luggage::evidence` has its own `EvidenceSource` trait. Apply the same
warn-not-block-with-timestamp rule to any future consumer of evidence.
