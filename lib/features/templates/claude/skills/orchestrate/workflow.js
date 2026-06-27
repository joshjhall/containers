export const meta = {
  name: 'orchestrate-monitor',
  description:
    'Budgeted, resumable fan-out for the live orchestrator over the OPEN-PR set: (1) polls PR CI/review state + issue status labels as authoritative, with a per-PR checkpoint so a crashed sweep resumes mid-list; (2) optionally classifies PRs behind base and dispatches the rebase-agent to auto-resolve trivial conflicts, surfacing the rest for the human. Both phases share ONE token budget. Never calls workflow() — the one Workflow nesting level is reserved for each golem process.',
  phases: [
    {
      title: 'Poll',
      detail: 'fan read-only PR-status reads across the open-PR set (parallel barrier, per-PR checkpoint)',
    },
    {
      title: 'Rebase',
      detail: 'classify PRs behind base; dispatch rebase-agent for trivial conflicts; collect resolved/escalated',
    },
  ],
}

// ---------------------------------------------------------------------------
// Input (passed verbatim as the global `args`):
//   {
//     prs: [{                 // the OPEN-PR set the orchestrator already enumerated
//       number: number,       // PR / MR number
//       branch: string,       // head branch (the golem's branch)
//       issue:  number,       // linked issue number (from "Closes #N" in the PR body)
//       golem?: string,       // golem id (agentNN / worktree label) — display + cache key only
//     }],
//     base: string,           // base branch the PRs target (default 'main')
//     mode: 'poll' | 'poll+rebase',  // default 'poll'; 'poll+rebase' enables the Rebase phase
//     maxRebases?: number,    // default = prs.length — the harness owns this cap
//   }
//
// Returns:
//   {
//     base,
//     pr_status:   [PR_STATUS],     // one per polled PR (null-failed reads filtered out)
//     rebases:     [REBASE_RESULT], // present only in poll+rebase mode
//     escalations: [{ pr, file, reason, ours_summary?, theirs_summary? }],  // for the human
//     budget_exhausted: boolean,
//     polled: number, rebased: number,
//   }
//
// The orchestrator session is LIVE/INTERACTIVE and is NOT this workflow — it
// INVOKES this harness for one bounded sweep, reads the result, refreshes its
// table, and takes the next human command. This harness never dispatches golems,
// never merges into the orchestrator branch, and never pushes: it returns results
// and the live orchestrator pushes rebased branches (--force-with-lease) under
// human supervision. PR + issue-label state are authoritative; the
// .worktrees/.status/*.json cache is consulted only to fill display gaps.
// ---------------------------------------------------------------------------

const prs = (args && Array.isArray(args.prs) ? args.prs : []).filter(Boolean)
const base = args && typeof args.base === 'string' && args.base ? args.base : 'main'
const MODE = args && args.mode === 'poll+rebase' ? 'poll+rebase' : 'poll'
const MAX_REBASES = args && Number.isInteger(args.maxRebases) ? args.maxRebases : prs.length

// Stop spawning fan-out work once the shared budget gets this close to empty, so
// a partially-complete sweep still returns its results instead of throwing
// mid-barrier. Matches the floor used by the ci-fixer / review harnesses.
const BUDGET_FLOOR = 40_000

// Conflict-class taxonomy — lifted verbatim from merge-protocol.md's
// "Conflict Classification for Cross-PR Rebase" decision tree. The first six
// are auto-resolvable by rebase-agent; the last three escalate to the human.
// `union` covers composable same-region edits — each side adds a distinct,
// non-contradictory change, so the agent keeps the superset of both rather than
// escalating (the general form of the `imports` combine rule).
const CONFLICT_CLASSES = [
  'lockfile',
  'generated',
  'imports',
  'union',
  'version',
  'whitespace',
  'logic',
  'add-add',
  'delete-modify',
]

// ---------------------------------------------------------------------------
// StructuredOutput schemas (typed gates — all additionalProperties:false).
// ---------------------------------------------------------------------------

// Authoritative per-PR state: PR/MR platform state wins over the status cache.
// label_state mirrors the live taxonomy owned by next-issue / next-issue-ship.
const PR_STATUS = {
  type: 'object',
  additionalProperties: false,
  required: ['pr', 'issue', 'branch', 'ci', 'review', 'label_state', 'behind_base', 'blocking', 'summary'],
  properties: {
    pr: { type: 'integer' },
    issue: { type: 'integer' },
    branch: { type: 'string' },
    ci: { type: 'string', enum: ['pending', 'passing', 'failing', 'none'] },
    review: { type: 'string', enum: ['none', 'changes-requested', 'approved', 'commented'] },
    label_state: {
      type: 'string',
      enum: ['in-progress', 'commit-pending', 'pr-pending', 'on-hold', 'none'],
    },
    behind_base: { type: 'boolean' },
    blocking: { type: 'boolean' },
    review_cycle: { type: 'integer', minimum: 0 },
    summary: { type: 'string' },
  },
}

// Cheap pre-classify before any rebase attempt: decides whether to dispatch the
// rebase-agent at all (none / trivial-only) or escalate the whole PR (has-logic).
const OVERLAP = {
  type: 'object',
  additionalProperties: false,
  required: ['pr', 'rebase_needed', 'conflict_files', 'overlap'],
  properties: {
    pr: { type: 'integer' },
    rebase_needed: { type: 'boolean' },
    conflict_files: { type: 'array', items: { type: 'string' } },
    overlap: { type: 'string', enum: ['none', 'trivial-only', 'has-logic'] },
  },
}

// Mirrors the rebase-agent's native {resolved, escalated} direct-mode contract
// exactly (see agents/rebase-agent/rebase-agent.md — the agent returns only
// these two fields). The harness stamps pr/branch/rebased onto the result after
// the agent returns; they are NOT agent-supplied, so they must not be required
// here or schema validation would force the agent to fabricate them.
const REBASE_RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['resolved', 'escalated'],
  properties: {
    resolved: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'strategy'],
        properties: { file: { type: 'string' }, strategy: { type: 'string' } },
      },
    },
    escalated: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'reason'],
        properties: {
          file: { type: 'string' },
          reason: { type: 'string' },
          ours_summary: { type: 'string' },
          theirs_summary: { type: 'string' },
        },
      },
    },
  },
}

const READONLY_POLL =
  'STRICTLY READ-ONLY: query PR/MR + issue state via gh/glab only. Do NOT edit, ' +
  'stage, commit, push, merge, rebase, or touch any git ref. Issue status labels ' +
  'and PR/MR state are authoritative; the .worktrees/.status/*.json cache may be ' +
  'stale — always prefer the live query.'

const REBASE_GUARDRAILS =
  'Operate ONLY on the PR head branch, rebasing it onto the base branch. Do NOT ' +
  'push, force-push, merge, open/close PRs, or touch the orchestrator branch — the ' +
  'live orchestrator pushes the rebased branch under human supervision. When both ' +
  'sides touched the same region, union complementary non-contradictory edits ' +
  '(keep the superset) before escalating. Escalate only genuinely contradictory ' +
  'conflicts (contradictory logic, contradictory add-add, or delete-modify) ' +
  'instead of guessing.'

const pollPrompt = (pr) =>
  `Report the current state of PR #${pr.number} (head branch "${pr.branch}", ` +
  `linked issue #${pr.issue}) targeting base "${base}".\n\n` +
  `Gather, via gh/glab: CI/checks rollup (pending/passing/failing/none), latest ` +
  `review decision (none/changes-requested/approved/commented), the issue's ` +
  `status/* label (in-progress/commit-pending/pr-pending/on-hold/none), whether ` +
  `the branch is behind "${base}" (base advanced since branch point), the number ` +
  `of observed review rounds, and whether the PR is blocking (needs human action: ` +
  `red CI, changes-requested, or merge conflicts). One-line summary. ` +
  READONLY_POLL

const overlapPrompt = (pr) =>
  `PR #${pr.number} (branch "${pr.branch}") is behind base "${base}". Without ` +
  `mutating anything, determine whether a rebase onto "${base}" is needed and ` +
  `classify the overlap of conflicting files: "none" (no conflicts), ` +
  `"trivial-only" (only lockfiles / generated / imports / version / whitespace, ` +
  `OR composable same-region edits whose two sides are complementary and ` +
  `non-contradictory — unionable, keep the superset; this includes a composable ` +
  `add-add where each side adds a distinct, non-conflicting block), or ` +
  `"has-logic" (any same-region conflict whose sides genuinely contradict and ` +
  `cannot be unioned — including a contradictory add-add — or any delete-modify ` +
  `conflict). List the conflicting files. ` +
  READONLY_POLL

const rebasePrompt = (pr, ov) =>
  `Rebase PR head branch "${pr.branch}" (PR #${pr.number}) onto base "${base}". ` +
  `Conflicting files: ${ov.conflict_files.join(', ') || '(detect during rebase)'}. ` +
  `Classify each conflict and apply the appropriate trivial strategy ` +
  `(${CONFLICT_CLASSES.slice(0, 6).join(' / ')}); for a same-region conflict, ` +
  `union complementary non-contradictory edits (keep the superset) before ` +
  `escalating; escalate only genuinely contradictory conflicts. ` +
  `Return resolved[] and escalated[]. ` +
  REBASE_GUARDRAILS

// ---------------------------------------------------------------------------
// Phase 1 — Poll (parallel barrier; per-PR checkpoint via the Workflow journal).
// ---------------------------------------------------------------------------
phase('Poll')
let budgetExhausted = false

const statuses = (
  await parallel(
    prs.map((pr) => async () => {
      if (budget.total && budget.remaining() < BUDGET_FLOOR) {
        budgetExhausted = true
        log(`budget low — skipped poll of PR #${pr.number} (not in this sweep)`)
        return null
      }
      const s = await agent(pollPrompt(pr), {
        label: `poll:#${pr.number}`,
        phase: 'Poll',
        schema: PR_STATUS,
      })
      // A null here is an agent failure, NOT a budget skip (those returned
      // above). Log it so the PR doesn't silently vanish from the rendered
      // status table — a missing row reads as "merged/gone" to the human.
      if (!s) log(`poll FAILED for PR #${pr.number} — omitted from this sweep, re-poll to refresh`)
      return s
    }),
  )
).filter(Boolean) // null-resilience: a failed/skipped PR read drops out, the sweep continues

// ---------------------------------------------------------------------------
// Phase 2 — Rebase (only PRs the poll flagged behind base; loop-until-dry).
// ---------------------------------------------------------------------------
const rebases = []
const escalations = []

if (MODE === 'poll+rebase') {
  phase('Rebase')

  // Work list: PRs behind base, in PR order. Each is independently journaled, so
  // relaunching with resumeFromRunId resumes mid-list rather than from PR zero.
  const queue = statuses
    .filter((s) => s.behind_base)
    .map((s) => prs.find((p) => p.number === s.pr))
    .filter(Boolean)

  let i = 0
  while (i < queue.length && rebases.length < MAX_REBASES) {
    if (budget.total && budget.remaining() < BUDGET_FLOOR) {
      budgetExhausted = true
      log(`budget low — stopping rebase sweep after ${rebases.length} PR(s)`)
      break
    }
    const pr = queue[i++]

    const [result] = await pipeline(
      [pr],
      (p) =>
        agent(overlapPrompt(p), {
          label: `overlap:#${p.number}`,
          phase: 'Rebase',
          schema: OVERLAP,
        }),
      (ov) => {
        // Logic overlap (or a failed classify) → never auto-rebase; escalate.
        if (!ov || ov.overlap === 'has-logic' || !ov.rebase_needed) {
          // On a FAILED classify we have no file list, so a per-file escalation
          // map would be empty and the PR would surface nothing to the human —
          // it'd look quietly handled. Emit one synthetic whole-PR escalation in
          // that case so a classify failure is always visible.
          let escalated
          if (!ov) {
            escalated = [{ file: '(whole PR)', reason: 'overlap classify failed — manual rebase review' }]
          } else {
            escalated = ov.conflict_files.map((f) => ({
              file: f,
              reason: ov.overlap === 'has-logic' ? 'logic overlap — human review' : 'rebase not attempted',
            }))
          }
          return Promise.resolve({
            pr: pr.number,
            branch: pr.branch,
            rebased: false,
            resolved: [],
            escalated,
          })
        }
        // Trivial-only (or no-conflict) → dispatch the existing rebase-agent.
        // The agent returns only { resolved, escalated }; stamp pr/branch/rebased
        // so this path's result matches the escalation branch's shape above.
        // A null/skipped agent result stays null (the `if (result)` guard below
        // handles it).
        return agent(rebasePrompt(pr, ov), {
          label: `rebase:#${pr.number}`,
          phase: 'Rebase',
          agentType: 'rebase-agent',
          schema: REBASE_RESULT,
        }).then((r) => r && { pr: pr.number, branch: pr.branch, rebased: true, ...r })
      },
    )

    if (result) {
      rebases.push(result)
      for (const e of result.escalated) escalations.push({ pr: pr.number, ...e })
    }
  }
}

return {
  base,
  pr_status: statuses,
  rebases,
  escalations,
  budget_exhausted: budgetExhausted,
  polled: statuses.length,
  rebased: rebases.length,
}
