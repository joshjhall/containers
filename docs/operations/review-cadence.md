# Review Cadence

Dep health, security posture, and tech-debt triage need a forcing function or
they silently rot. This page describes the layered cadence — what runs
automatically every week, what the team runs manually each quarter, and what
each finding means when it lands.

## Overview

| Cadence         | Trigger                                        | What happens                                                           |
| --------------- | ---------------------------------------------- | ---------------------------------------------------------------------- |
| Weekly (Sun)    | `auto-patch.yml` at 02:00 UTC                  | Version-bump sweep → PR → auto-merge if CI passes                      |
| Weekly (Mon)    | `security-scan.yml` at 03:00 UTC               | `cargo deny` + `osv-scanner` + `cargo audit`; opens issue on findings  |
| Quarterly (1st) | `quarterly-review.yml` at 09:00 UTC            | Opens tracking issue for Q1/Q2/Q3/Q4 with the manual checklist         |
| Ad-hoc          | Human runs `just quarterly-review` locally     | Informational sweep: `machete` + `geiger` + `outdated` + `deny bans`   |
| Ad-hoc          | Human runs `/codebase-audit` in Claude Code    | Parallel scanner agents file `audit/*` issues for human triage         |

## What runs automatically

### `auto-patch.yml` — weekly version bumps

Sunday 02:00 UTC. Walks every pinned tool version in `lib/features/*.sh`,
queries upstream registries (crates.io, PyPI, npm, GitHub releases), opens a
patch-bump PR, and auto-merges on green CI. See
[`automated-releases.md`](automated-releases.md) for the full flow, Pushover
setup, and monitoring.

### `security-scan.yml` — weekly vulnerability scan

Monday 03:00 UTC. Runs `just security-scan` in CI. On any finding it opens
(or updates) a single tracking issue labeled `severity/high` +
`type/compliance` + `audit/security`. Resolution is either a dependency
bump or a narrow ignore in `deny.toml` / `.osv-scanner.toml`.

### `quarterly-review.yml` — quarterly tracking issue

1st of Jan/Apr/Jul/Oct, 09:00 UTC. Opens an issue titled
`Quarterly review: YYYY-Q#` labeled `type/chore` + `type/operations` with
the manual checklist below. The workflow is idempotent: if the issue for the
current quarter is already open, the run is a no-op.

## What runs manually each quarter

When a quarterly tracking issue lands:

### 1. Run the informational sweep

```bash
just quarterly-review
```

This runs four cargo tools in sequence, prints section headers, and **never
fails the recipe** — the point is to collect signals to review, not to gate:

- **`cargo machete`** — unused workspace dependencies. False positives are
  common on feature-gated imports; verify before deleting.
- **`cargo geiger --all-features`** — unsafe-code surface. Look for deltas
  against the previous quarter; steady growth is worth investigating.
- **`cargo outdated --workspace --root-deps-only`** — direct dependency age.
  Transitive drift is handled by the weekly `auto-patch`; this is the
  major/minor bumps `auto-patch` leaves alone.
- **`cargo deny check bans sources`** — duplicate-version and
  registry/git-source drift. Finds cases where a transitive dep pulled in a
  second copy of a crate or a crate from an unexpected source.

### 2. Run `/codebase-audit` in Claude Code

Parallel scanner agents produce `audit/*` issues (security, code-health,
docs, tests, architecture, config). Human triage decides which to fix, defer,
or close.

### 3. Work the checklist in the tracking issue

- Review open `audit/*` issues — close stale ones, reprioritize the rest.
- Update pinned versions that `auto-patch` doesn't touch (major bumps,
  GitHub Actions, pre-commit hooks).
- Rotate long-lived secrets if the team's age policy calls for it.
- Prune allowlists in `.trivyignore`, `.osv-scanner.toml`, and `deny.toml` —
  remove entries where the upstream fix has landed.

## Acting on findings

| Tool                          | Output type        | Action                                                               |
| ----------------------------- | ------------------ | -------------------------------------------------------------------- |
| `cargo machete`               | Unused dep list    | Verify (feature gates!), then remove from `Cargo.toml`                |
| `cargo geiger`                | Unsafe count table | Compare to prior quarter; investigate sustained growth               |
| `cargo outdated`              | Version deltas     | Bump in `Cargo.toml`; test; ship via normal PR                       |
| `cargo deny bans/sources`     | Duplicate/drift    | Add `skip` / `skip-tree` entry to `deny.toml` or bump offender        |
| `/codebase-audit` findings    | `audit/*` issues   | Triage into `severity/*` + `effort/*`; work via `/next-issue`        |
| `security-scan.yml` findings  | Tracking issue     | Fix the advisory or add a narrow allowlist entry; close the issue    |

## Cadence rationale

Quarterly lands between two failure modes. Weekly is too noisy for
judgment-heavy checks (`cargo machete` false-positives on feature flags,
`geiger` deltas look like noise at weekly granularity). Semi-annual is too
stale — duplicate-version drift and `audit/*` findings compound across six
months until nobody wants to read the backlog. Quarterly is short enough that
findings are tractable, long enough that the checks aren't crying wolf.

Start here; move individual checks to tighter or looser cadences only after
two or three quarters of signal show the current cadence is wrong.

## Manual triggers

```bash
# Trigger the quarterly tracking issue now (e.g., to test)
gh workflow run quarterly-review.yml

# Run the informational sweep anytime
just quarterly-review
```

## Workflow files

- `.github/workflows/auto-patch.yml` — weekly patch-bump automation
- `.github/workflows/security-scan.yml` — weekly dependency security scan
- `.github/workflows/quarterly-review.yml` — quarterly tracking issue
