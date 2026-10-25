---
name: review-fix-commit-scope
description: "librarian ship protocol suggests `fix(review): …` commits, but this repo's conform scope allowlist rejects `review` — use the component scope"
metadata:
  node_type: memory
  type: feedback
  originSessionId: f7f428b5-b35f-439e-8d19-45d3798ae9e6
  modified: 2026-10-25T19:57:27.683Z
---

The librarian `ship-issue` CI/review protocol names review-fix commits
`fix(review): …` and CI fixes `fix(ci): …`. In this repo `conform` (commit-msg
hook, `.conform.yaml`) has **no `review` scope**, so a `fix(review): …` commit is
rejected at commit time (`Invalid scope "review"`), and nothing is committed.

**Why:** `.conform.yaml` is the scope source of truth and curates scopes by
component; `review` is a workflow concept, not a component. (`ci` *is* allowed.)

**How to apply:** commit review-loop fixes under the touched component's scope
with a fitting type, e.g. `test(luggage): …` or `fix(luggage): …`
(#1352 / PR #1369). Don't add a `review` scope to `.conform.yaml` just to match the
protocol's wording.
