---
name: empty-review-dimension-is-not-a-pass
description: "ship-issue reviewers often submit {findings:[]} without reading code (21% of Sonnet runs, 17 security); audit engagement from agent meta+jsonl, not the verdict"
metadata:
  node_type: memory
  type: feedback
  originSessionId: a5119337-03a4-4576-8119-a6b964540063
  modified: 2026-10-04T01:51:59.290Z
---

On 2026-10-03, 54 of 250 ship-issue review-dimension runs across 12 golems were
**empty**. Each one's only tool call was `StructuredOutput({findings: []})`, with
about 53 output tokens, no Read/Grep/Bash, and no reasoning. The harness counted
them as clean. `security` was empty 17 times; on #941 it was empty in all 6
cycles. All 250 runs were on `claude-sonnet-5-5`. Unlike
[[degraded-review-gate-is-not-a-pass]], nothing shows up in `<failures>`: the
dimension *succeeded* and said nothing. One golem's manual re-check of an
"empty-clean" diff found a real bug every reviewer had missed (#1032, a
push-time test selector dropping suites). Filed upstream as librarian#1111.

**Why:** "investigated and found nothing" and "never looked" produce the same
`{findings: []}`. The #553 exploration budget ("~10 tool calls") plus the inline
diff lets Sonnet answer without engaging. A golem's prose check ("reviewers
reasoned") can't tell the difference either. Measure it.

**How to apply:** before trusting a clean cycle, audit engagement per dimension.
Each reviewer subagent has `~/.claude/projects/<worktree>/<session>/subagents/workflows/wf_*/agent-*.meta.json`
(`description: "review:security"`) beside its `.jsonl`. Count `tool_use` blocks
whose `name != "StructuredOutput"`, and sum `message.usage.output_tokens`. Zero
investigative calls plus ≤60 tokens plus no thinking/text means it was empty.
Don't count `StructuredOutput` as a tool call, or every empty run looks engaged.
For an empty dimension, re-run it with an explicit single-dimension contract on
`model: "opus"` ([[ship-review-harness-provider-error]]) before merging, and say
plainly that the gate was degraded. Security-relevant PRs get a manual security
review regardless.

**Related orchestrator lesson (same session):** to decline a golem's permission
prompt, send `Esc`, never a digit. Menus vary (`1 Yes / 2 No`, or
`1 Yes / 2 Yes-and-don't-ask / 3 No`). A digit picked for one shape approved
merges on #1028 and #1034 that the operator had declined.
