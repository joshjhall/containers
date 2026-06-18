---
name: parallel-automation-golem-initiative
description: "Plan + execution order for the parallel-automation (golem) initiative — autonomous next-issue pipeline, adversarial review loop, PR-per-golem orchestrator"
metadata:
  node_type: memory
  type: project
  originSessionId: af6cb49e-bd1e-4a29-b731-4af69399c170
---

Initiative: run N independent **golems** (per-issue sub-orchestrators), each owning
one issue → branch → worktree → PR, iterating to a green, review-clean PR that a
human merges. Master orchestrator dispatches + monitors + resolves cross-PR
conflicts. Goal: churn hundreds of Octarine issues with little oversight.

**Naming (decided):** `golem` for the per-issue sub-orchestrator — fits the
Discworld theme (stibbons/igor/luggage); one instruction, tireless autonomous
work, many at once. Topology: `orchestrator (live session) → dispatches → golems
(processes) → spawn → Workflow agents`.

**Decisive architecture constraint:** the Workflow tool allows only ONE level of
nesting (`workflow()` inside a workflow throws). A golem runs `/next-issue-ship`
which invokes a `workflow.js`, so **golems must be processes** (terminal / container
/ worktree-session), never Workflow subagents. The **orchestrator is a live
interactive session** (it surfaces to the human + takes mid-flight commands), using
Workflow ONLY for bounded fan-out (monitor poll, cross-PR rebase) — not the
orchestrator lifecycle.

**Stop point:** review → resolve-or-defer → commit → re-review, looping until
(no blocking findings) ∧ (CI green) ∧ (all comments resolved-or-deferred), then a
structured summary; **human decides the merge**. No auto-merge except the existing
`AUTOMERGE=1` escape hatch. Deferred findings filed via `/file-issue`, linked on PR.

**Autonomy trigger:** `/next-issue 123 --auto` (interactive) + `NEXT_ISSUE_AUTONOMOUS=1`
(ambient, baked into provisioned containers). Interactive defaults stay byte-for-byte
unchanged — autonomy is strictly opt-in (these are templates shipped into every
built container).

**Skills are templates** at `lib/features/templates/claude/skills/<skill>/` (and
`.../agents/<agent>/`), NOT the live `.claude/skills/` — changes ship to every
built container. Use `/skill-authoring` + `/agent-authoring` for all edits; follow
epic [[v5-architecture]] #503 thin-shell Workflow conventions.

**Execution order:**
`#523 → #498 → #527 → [reconcile #500] → #524 → #501 → #525`, then update
`#310`/`#309`/`#268` to match what was built

- #523 — Axis A: autonomous mode (gate removal only). Foundational, no harness dep
  beyond shipped #499 (ci-fixer). START HERE.
- #498 — code-reviewer Workflow harness (epic #503 sub-issue). Prereq for #527.
- #527 — Axis B: adversarial pre-PR review + multi-cycle review loop. Consumes #498.
- #500 — RECONCILE (decision, not code): close / narrow / fold into #524. #500
  harnesses the OLD local-merge topology #524 retires. Do before #524.
- #524 — Axis C: master-orchestrator PR-per-golem topology. Demotes local-merge to
  opt-in. Leave rebase dispatch as a clean seam for #501.
- #501 — rebase-agent harness; upgrades #524's cross-PR rebase dispatch (#524 can
  initially use the model-driven rebase-agent).
- #525 — provision-agent: wire entrypoint to launch the autonomous golem pipeline.

**Stibbons/igor Rust-port issues intersect** (separate v5 port initiative) — flagged
with cross-links so they don't bake in the retired topology: #310 (ports the
`agent-entrypoint.sh` #525 rewrites — parameterize entrypoint/delivery), #309
(keep `worktree sync` generic = rebase-onto-base), #268 (`agent status` should read
PR + issue-label state as authoritative). Update these AFTER the architecture lands.

**Off-path (no edits):** #497 (codebase-audit), #502 (matrix-build-verify).
