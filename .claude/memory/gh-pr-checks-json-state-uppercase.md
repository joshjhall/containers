---
name: gh-pr-checks-json-state-uppercase
description: gh pr checks --json state returns UPPERCASE values; filter on bucket (lowercase) when monitoring CI
metadata:
  node_type: memory
  type: reference
  originSessionId: bd252102-8f9d-4b04-9312-d0db159a1c49
---

`gh pr checks <PR> --json name,state,bucket` returns the `state` field in
UPPERCASE (`IN_PROGRESS`, `SUCCESS`, `QUEUED`), not lowercase. A monitor/poll
loop that filters `state` against lowercase (`"pending"`, `"in_progress"`)
silently misclassifies in-progress checks as terminal and exits early.

Filter on the **`bucket`** field instead — it is stable lowercase:
`pending` | `pass` | `fail` | `skipping` | `cancel`. To detect "all checks
done": `[.[] | select(.bucket=="pending")] | length == 0`; failures:
`select(.bucket=="fail")`.

Hit while monitoring PR #590 CI in /next-issue-ship. Relevant to the Monitor
tool poll-loops and the ci-fixer hand-off in [[golem-supervised-auto-mode]].
