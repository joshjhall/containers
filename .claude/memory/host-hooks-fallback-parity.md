---
name: host-hooks-fallback-parity
description: "The two host-monitoring hooks share an identity ladder; their python/jq-absent fallbacks both need injection sanitization (#756)"
metadata:
  node_type: memory
  type: project
  originSessionId: 23e9e11c-3ae6-48f0-8b7f-d5488d95b4b4
  modified: 2026-07-22T03:29:05.612Z
---

The two host-monitoring hooks — `lib/features/templates/claude/hooks/claude-host-event.sh`
(POSTs `<project>-<role>-<short>` to the host bridge) and
`.claude/hooks/golem-notify.sh` (appends `<role>-<short>` to the golem feed) —
share one identity-resolution ladder (GOLEM_ID → worktree-root → AGENT_ID
[host-event only] → orchestrator marker → primary), so their two feeds agree on
who a session is. Keep their **test suites symmetric**: they are hand-copied case
ladders that drift if only one is edited (that drift-risk is the whole point
of #756/#750).

Non-obvious gotcha: BOTH hooks have a **minimal-environment fallback** (python3
absent in host-event; jq absent in golem-notify) that hand-rolls the JSON by
string interpolation. Any attacker-influenceable field flowing into that literal
(`$golem` from an **unvalidated** `AGENT_ID` — only `GOLEM_ID` is regex-gated —
or `$project` from `PROJECT_NAME`) MUST be sanitized: drop backslashes, escape
quotes, pure-bash (no `tr` — the fallback path runs precisely when the env is
minimal). golem-notify guarded this from the start (`test_jq_absent_fallback_valid_json`);
host-event's python-absent branch did NOT until #756 added the same guard + test.

Known remaining asymmetry (tracked in #766): golem-notify has **no AGENT_ID arm**
at all, so an AGENT_ID-only container golem diverges between the two feeds.
Narrow in practice since #761 stamps GOLEM_ID. Builds on
[[host-activity-line-shows-pipeline-phase]].
