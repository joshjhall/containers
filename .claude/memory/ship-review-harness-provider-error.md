---
name: ship-review-harness-provider-error
description: ship-issue review harness 400s on provider resolution for Sonnet; re-dispatch the dimensions as reviewer agents with model=opus
metadata:
  node_type: memory
  type: feedback
  originSessionId: 7b034a08-9c8e-4e64-a2f2-abf270d0ddf9
  modified: 2026-09-28T21:21:32.846Z
---

The ship-issue adversarial review harness (`ship-issue/workflow.js`) can fail
every agent with `API Error: 400 could not auto resolve a provider for the
request, please specify a provider explicitly`. It returns `clean:false`,
`no_review_signal:true`, `blocking:[]`, 0 tokens, 0 dimensions run, and a
`[manifest] failed` entry in `<failures>` within ~200ms.

**Why:** the failing model is `claude-sonnet-5-5` (named in the agent error);
the session's own model still resolves. It is deterministic within a session —
a `resumeFromRunId` retry fails identically — and `dev-core:code-reviewer`
fails the same way because it also runs on Sonnet. Zero findings here means the
review never ran, not that it passed ([[degraded-review-gate-is-not-a-pass]]).

**How to apply:** do not ship on the empty result, and do not bother retrying
the harness. Re-dispatch the dimensions as `dev-core:code-reviewer` agents with
the Agent tool's `model: "opus"` override — on #986/#987 (PR #988) two of them
(correctness+security, tests+scope+decomposition) ran fine and found a real
unmet acceptance criterion the green CI would have merged over. Give each an
explicit dimension contract and the issue ACs; note in the PR body that the
harness was replaced and why.
