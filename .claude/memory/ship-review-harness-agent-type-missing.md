---
name: ship-review-harness-agent-type-missing
description: "ship-issue pre-PR review harness hardcodes dev-core:code-reviewer agent type, absent in golem env → fails fast; degrade gracefully"
metadata:
  node_type: memory
  type: project
  originSessionId: 66c22f94-ec40-46e5-8a80-c7d0cb04e2b2
---

The `/ship-issue` adversarial review harness (`skills/ship-issue/workflow.js`,
phase `pre-pr` / `pr-cycle`) fans out via `agentType: 'dev-core:code-reviewer'`.
In at least some golem/session environments that agent type is **not
registered** (only `pr-review-toolkit:*` and `review-audit:*` reviewers are
available), so the Workflow fails immediately with
`agent type 'dev-core:code-reviewer' not found` — 0 tokens, 1 agent error, ~1.4s.

This is the **documented graceful-degradation case**: pre-ship-validation.md says
"if the Workflow tool or workflow.js is unavailable, skip this step with a note —
never block shipping due to harness errors." Treat the missing-agent-type error
the same as harness-unavailable: skip the automated review, do a **manual
adversarial pass** over the diff's risk points, and proceed to push/PR.

Related: [[ship-review-harness-provider-error]] (the 400/provider-resolve variant
of the same "harness failure ≠ passing review" degradation). First seen #667/PR#685.
