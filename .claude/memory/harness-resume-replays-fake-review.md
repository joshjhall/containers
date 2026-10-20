---
name: harness-resume-replays-fake-review
description: "Passing resumeFromRunId to a later review cycle replays every agent from cache — 0 tokens, 0 tool uses, a stale \"clean\""
metadata:
  node_type: memory
  type: feedback
  originSessionId: 747a2b7e-a1e0-42a2-84a2-f176ffa3fc42
  modified: 2026-10-17T02:52:19.867Z
---

Never pass `resumeFromRunId` to start the **next** cycle of the ship-issue review
harness. The agent prompts don't depend on the cycle number, so every agent
replays its cached result. On #1269 the cycle-2 "review" finished in 12 ms with
`subagent_tokens: 0` and `tool_uses: 0`, and it reported the previous cycle's
findings as if they were new.

**Why:** a replayed cycle is byte-identical to a real one in `clean`/`blocking`.
Feeding it to `review-convergence.sh` would count as a reviewed cycle that never
happened. This is the same silent-pass class as [[harness-placeholder-args-fake-review]]
and [[empty-review-dimension-is-not-a-pass]].

**How to apply:** start every cycle as a fresh `Workflow` call with no resume.
Before trusting a result, check its `<usage>` (`subagent_tokens`, `tool_uses`,
`duration_ms`). Zero tokens means discard it and re-run fresh. Keep
`resumeFromRunId` for its documented use: re-running a single cycle after
editing the script.
