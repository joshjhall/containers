---
name: ship-review-harness-provider-error
description: next-issue-ship adversarial review harness can 400 on provider resolution; degrade gracefully
metadata:
  node_type: memory
  type: feedback
  originSessionId: 7b034a08-9c8e-4e64-a2f2-abf270d0ddf9
---

The `/next-issue-ship` adversarial review harness
(`~/.claude/skills/next-issue-ship/workflow.js`, Step 3.5 item 6 / Step 4 loop)
can fail to run its review agents with `API Error: 400 could not auto resolve a
provider for the request, please specify a provider explicitly` — the workflow
returns `clean:false` but with `blocking:[]`, `deferrable:[]`, 0 agent tokens,
0 tool uses, and a `[manifest] failed` entry in `<failures>`.

**Why:** that is a harness/provider-config failure, NOT a review verdict of
"clean". `clean:false` with zero findings and zero token usage means the review
never actually ran.

**How to apply:** treat it as the skill's documented graceful-degradation case
("Adversarial pre-PR review skipped (harness not available)") — note it and
proceed to push/PR, relying on the deterministic gates that DID run (cargo test,
clippy -D warnings, fmt, pre-push osv/cargo-deny/cargo-test). Do not block
shipping on it, and do not misread the zero-findings result as a passing review.
Related: [[preexisting-osv-vuln-blocks-push]], [[gh-pr-checks-json-state-uppercase]].
