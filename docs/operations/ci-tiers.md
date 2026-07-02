# CI Tiered Cadence

Container builds and integration tests are split across four cadence tiers,
trading depth of coverage for feedback speed. A PR sees only the features it
touched; the full distro × arch × feature matrix runs weekly. Evidence runs sit
alongside these as an event-driven tier that records per-tool install results
against signed base images. This page describes the design, what's implemented
today, and what's planned.

## Overview

| Tier      | Trigger                              | Wall-time budget | Matrix scope                                | Status                |
| --------- | ------------------------------------ | ---------------- | ------------------------------------------- | --------------------- |
| PR        | `pull_request` → main, v5            | <15 min          | Opt-in (`ci/full-build`): touched features × debian:trixie × amd64 | Implemented (#408); opt-in during v5 (#508) |
| Merge     | `push` → main, v5, `auto-patch/**`   | <30 min          | 4 representative variants × debian × amd64  | Implemented (ci.yml); slimmed for v5 (#508) |
| Weekly    | Cron Sundays 03:00 UTC               | <2 h             | All features × all distros × all arches     | Planned (#408-B)      |
| Monthly   | Cron 1st of month 04:00 UTC          | <4 h             | Long-tail: image size, abandonment scan     | Planned (#408-C)      |
| Quarterly | Cron 1st of Q 09:00 UTC (existing)   | Best-effort      | Cross-version dependency drift              | Planned (#408-D)      |
| Evidence  | `pull_request` + `push` → main       | <30 min          | Pilot: rust × debian-12-amd64 (extensible)  | Implemented (#478)    |

Promotion criteria are unidirectional — passing a faster tier is a prereq
for letting code reach the next slower tier, but a failure at a slower tier
does not block ongoing work (the regression opens an issue instead). Evidence
runs are off to the side of this chain: they don't gate merges, they record
what a published base image actually does when a tool is installed onto it.

The evidence tier records per-tool installs against signed base images, with
results landing in `joshjhall/containers-db`. It is event-driven (no cron) and
path-scoped — see the [Evidence runs](#evidence-runs) section below and
[evidence-runs.md](evidence-runs.md) for the ingestion contract.

## PR tier

**Status:** Implemented in [`.github/workflows/test-pr.yml`](../../.github/workflows/test-pr.yml).

The PR tier is the first time container builds run on a PR. Before this
tier existed, contributors got unit / Rust / lefthook checks on PR; the
container builds only ran post-merge in the merge tier. The PR tier closes
that gap with per-feature change detection so a one-feature PR doesn't pay
the full multi-variant merge-tier cost.

> **Opt-in during the v5 transition (#508).** The per-feature builds validate
> the legacy `lib/features/*.sh` bash scripts that v5's `luggage` engine is
> replacing, so their value decays while they still flake on runner resource
> limits (`golang-dev` disk exhaustion, the old `rust-dev` timeout). The tier
> is therefore **skipped by default** — `detect-changes` short-circuits to
> `mode=skip` unless the PR carries the **`ci/full-build`** label. Add that
> label when you want the full per-feature signal on a PR (e.g. a change deep
> in a feature script); routine PRs run only the code-level checks and merge
> against the merge tier's coverage. Remove this gate once the per-feature
> scripts are retired.

### Flow

1. `detect-changes` job runs [`tests/changed_features.sh`](../../tests/changed_features.sh)
   against the PR diff. The script maps changed files to feature names
   (canonical set: keys of `FEATURE_MAP` in
   [`tests/test_feature.sh`](../../tests/test_feature.sh)).
2. The result is one of three modes:
   - **skip**: the `ci/full-build` label is absent (opt-in gate, #508), or no
     container-affecting changes (docs / unit tests only)
   - **changed**: a list of touched features → fan out a matrix cell each
   - **full**: a foundational file changed (`Dockerfile`, `lib/base/**`,
     `lib/runtime/**`, `tests/framework/**`, `crates/**`) → fall back to
     the merge-tier cluster on this PR
3. `build-feature` matrix builds each feature image with buildx + GHA cache.
4. `pr-tier` summary job rolls up matrix results into a single status check
   for branch protection.

### Cache strategy

Per-feature, per-PR scopes with main fallback:

```yaml
cache-from: |
  type=gha,scope=feature-${FEATURE}-pr-${PR_NUMBER}
  type=gha,scope=feature-${FEATURE}-main
cache-to: type=gha,scope=feature-${FEATURE}-pr-${PR_NUMBER},mode=max
```

The PR scope keeps PR1's cache from poisoning PR2's. The main fallback
warm-starts the first build in a PR from the most recent merged state, so
contributors don't pay a cold-cache cost just for opening a PR.

### Cache-hit reporting

Every build job emits a `::notice::Cache hit rate: N%` annotation and
appends a section to `$GITHUB_STEP_SUMMARY`. Numbers are coarse (counted
via `docker history`), but stable across runs and grep-able in CI logs —
the acceptance criterion ("cache hit rate measurable") prioritizes
visibility over precision.

### Failure diagnostics

When a feature build aborts, the failing cell is diagnosable without
scrolling the raw log (issue #583):

- The in-container build harness emits a greppable `>>> BUILD FAILURE: …`
  sentinel naming the **feature** and the **exact command** that failed, and
  (under CI) collapses each feature install into a `::group::`.
- A runner-side `Surface build failure` step writes the failing
  variant/feature to `$GITHUB_STEP_SUMMARY` and emits an `::error`, so the
  checks list and job summary name the broken cell directly.

To find the root cause in a failed run, grep the log for `>>> BUILD FAILURE`.
See [structured-logging-reference.md](../observability/structured-logging-reference.md#github-actions-build-diagnostics)
for the full contract and the BuildKit line-prefix caveat.

### Promotion criterion

If the PR tier passes, the PR is eligible for review and merge. On merge,
the same SHA triggers the merge tier (`ci.yml`).

## Merge tier

**Status:** Implemented in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)
(`build` + `integration-test` jobs).

The merge tier exercises four representative multi-feature variants:

- `minimal` — baseline
- `python-dev`, `node-dev` — per-language stacks
- `polyglot` — python + node + dev-tools + clients

> **Slimmed for the v5 transition (#508).** The heavy legs — `rust-golang`,
> `r-dev`, `java-dev`, `cloud-ops`, and the `production` variant — are
> **parked, not deleted**: they were dropped from the `build`,
> `integration-test`, `security-scan`, and `release` jobs because they
> exercise the legacy per-feature bash scripts v5's `luggage` engine replaces,
> and they flaked on runner resource limits for decaying value. Re-add a
> variant to the `build` matrix (keeping `integration-test` in sync) to restore
> its coverage.

Same trigger as before (push to main / v5 / auto-patch, plus
`workflow_dispatch`). It explicitly does **not** trigger on `pull_request` —
the PR tier handles that path. Branch protection rules should require both
"PR Tier" and the merge-tier checks before allowing merge.

### Cache strategy

As of this PR, the global `type=gha` cache has been replaced with
variant-scoped caches:

```yaml
cache-from: |
  type=gha,scope=merge-${VARIANT}
  type=gha,scope=feature-${VARIANT}-main
cache-to: type=gha,scope=merge-${VARIANT},mode=max
```

The `feature-*-main` fallback lets the merge tier warm-start from the PR
tier's main-branch cache.

## Weekly tier

**Status:** Planned, tracked in **#408-B**.

The full matrix — every feature × every supported distro (Debian 11 / 12 /
13, Alpine, RHEL/UBI, Ubuntu) × every arch (amd64, arm64) — runs Sundays at
03:00 UTC. This is the regression-detection tier: cross-cutting changes
that pass PR and merge tiers but break a less-common distro/arch
combination get caught here.

### Cron slot

`0 3 * * 0` — Sunday 03:00 UTC. Reserved relative to existing schedule:

| Existing schedule | When         | Why we slot weekly after |
| ----------------- | ------------ | ------------------------ |
| `auto-patch.yml`  | Sun 02:00    | 1h gap so auto-patch's PR-creation completes before the full matrix starts |
| `security-scan.yml` | Mon 03:00  | Separate concerns: security scan runs on Monday |

### Auto-issue on failure

Failed runs open or update a tracking issue rather than blocking merge
(weekly findings should not gate ongoing PR work). Issues are labeled:

- `severity/medium` — full matrix regression, not a security finding
- `audit/regression` — produced by automated scanning
- `type/operations` — owned by the operations rotation

Pattern modeled on `security-scan.yml` lines 75-124: search for an existing
open issue by title, update it with the latest run URL on re-failure,
create a new one otherwise. Pseudocode:

```yaml
- name: Open or update tracking issue on failure
  if: failure()
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
  run: |
    TITLE="Weekly full-matrix regression"
    EXISTING=$(gh issue list --label "audit/regression" --state open \
      --search "\"${TITLE}\" in:title" --json number --jq '.[0].number // empty')
    if [ -n "${EXISTING}" ]; then
      gh issue comment "${EXISTING}" --body "Regression again — ${RUN_URL}"
    else
      gh issue create --title "${TITLE}" \
        --label "severity/medium" --label "audit/regression" --label "type/operations" \
        --body "..."
    fi
```

## Monthly tier

**Status:** Planned, tracked in **#408-C**.

`0 4 1 * *` — 1st of month, 04:00 UTC. Long-tail checks that don't fit the
weekly budget:

- **Image size regression**: compare image sizes against the baseline
  recorded in [`docs/ci/build-metrics.md`](../ci/build-metrics.md). Open a
  `severity/low` issue when any variant grows >100MB or >20%.
- **Abandonment scan**: cross-check `lib/features/*.sh` version pins
  against the activity tiers tracked in
  [`crates/luggage`](../../crates/luggage/) (see the
  `luggage-tooldb-design.md` memory). Flag tools that have moved into the
  `dormant` or `abandoned` tier — they should either be unpinned, swapped,
  or formally deprecated.
- **Stress tests**: parallel build of all variants on the same runner —
  surfaces disk-pressure, network-contention, and apt-lock race conditions
  that the spaced-out weekly matrix never reproduces.

## Quarterly tier

**Status:** Planned, tracked in **#408-D**.

Piggy-backs on the existing `quarterly-review.yml` schedule
(`0 9 1 1,4,7,10 *` — 1st of Jan/Apr/Jul/Oct at 09:00 UTC). Adds one new
check to the quarterly tracking issue:

- **Cross-version dependency drift**: run a representative tool-version
  combination matrix (current pinned Python × current Node × current Rust
  vs. one version older × current vs. one version newer × current, etc.)
  against the polyglot integration test. Catches the case where two tools
  individually upgrade smoothly but interact badly with the version of a
  third tool that hasn't moved.

Uses [`bin/check-versions.sh --json`](../../bin/check-versions.sh) to
enumerate the pinned versions; combinations are sampled rather than
exhaustive (full Cartesian product is infeasible for >50 tools).

## Evidence runs

**Status:** Implemented in
[`.github/workflows/evidence-run.yml`](../../.github/workflows/evidence-run.yml).

Unlike the cadence tiers above, the evidence tier is not about catching
regressions in *this* repo — it produces a durable record of what a published
base image does when a real tool is installed onto it. Each run builds
[`luggage`](../../crates/luggage/) and
[`record-evidence`](../../crates/record-evidence/) from this repo, pulls a
signed base image at its `sha256:` digest, runs `luggage install <tool>@<version>`
inside it, and assembles a `TestEntry`-shaped row. The row is delivered to
`joshjhall/containers-db` via [`bin/ingest-evidence.sh`](../../bin/ingest-evidence.sh).

### Cadence

Event-driven, not cron. Per [#473](https://github.com/joshjhall/containers/issues/473),
while the tool catalog is small "just enumerate" beats sampling, so the matrix is
exhaustive rather than scheduled. Three triggers, all **path-scoped** to evidence
sources (`crates/luggage/**`, `crates/record-evidence/**`,
`crates/containers-common/**`, `base-images/**`, `bin/ingest-evidence.sh`, and the
workflow itself) so unrelated PRs don't pay the build-and-install cost:

| Trigger             | Ingest behavior                                       |
| ------------------- | ----------------------------------------------------- |
| `pull_request` → main | Dry-run: validate the row merges cleanly against the catalog schema. Fork-safe — no secrets. |
| `push` → main       | Real ingest: open a PR against `joshjhall/containers-db` (requires the `CONTAINERS_DB_PAT` secret). |
| `workflow_dispatch` | Single ad-hoc leg from inputs; the `dry_run` input chooses validate vs. real ingest. |

A `setup` job resolves the matrix (a single input-derived leg for dispatch, the
enumerated pilot legs for PR/push) and the effective dry-run flag, keeping the
`evidence` job body identical across events. A `concurrency` group serializes
runs on the same ref so two main pushes can't race to open duplicate PRs.

### What it produces

One `TestEntry` row per `(tool, version, tuple)` leg, dedup-merged into
`tools/<tool>/versions/<version>.json` in containers-db by
`(os, os_version, arch, image_digest)`. The pilot leg is
`rust@1.95.0 × debian-12-amd64`; add tuples or tools to the matrix in the
`setup` job as their base images publish.

### What it consumes

- **Signed base images** from [`base-images/`](../../base-images/) (cosign +
  SBOM), pulled by digest so the evidence is reproducible.
- **The containers-db catalog**, cloned once and mounted read-only into the
  install container so luggage knows *how* to install the tool.
- **`luggage` + `record-evidence`**, built from this repo and mounted into the
  base image — the luggage release pipeline is deferred until v5 stabilizes, so
  the binary is mounted rather than installed from a package.

### Failure behavior

A failed `luggage install` is not a workflow failure — it is the evidence. The
install step runs under `set +e`, and luggage writes its `--json-report` on
every exit path (success, skip, dry-run, and failure). `record-evidence` maps a
populated `error_class` to `result: fail`, so a broken install still produces a
row recording *why* it broke. See [evidence-runs.md](evidence-runs.md) for the
wire format, transport, auth model, merge policy, and failure modes.

## Cache strategy summary

| Scope                            | Producer                  | Consumers                                              |
| -------------------------------- | ------------------------- | ------------------------------------------------------ |
| `feature-${F}-pr-${PR}`          | PR tier per-feature build | Subsequent runs of the same PR (rebases, fix-up commits) |
| `feature-${F}-main`              | Merge tier on main        | PR tier's first cold build                             |
| `merge-${VARIANT}`               | Merge tier on main        | Subsequent merges of the same variant                  |

Scopes never overlap, so two concurrent PRs cannot poison each other's
caches. The historical global `type=gha` scope is no longer used.

## Adding a new feature to the PR tier

1. Add the feature to `FEATURE_MAP` in
   [`tests/test_feature.sh`](../../tests/test_feature.sh) — the PR tier's
   feature → INCLUDE_* mapping is sourced from there.
2. If the feature has its own integration test under
   `tests/integration/builds/`, add a `# @tier: ...` header line declaring
   which tiers it belongs to:

   ```bash
   #!/usr/bin/env bash
   # @tier: pr,merge,weekly
   ```

   Absence of the header defaults to `merge` (the pre-tier behavior).
3. The PR tier's `changed_features.sh` will automatically pick up the new
   feature on diffs that touch `lib/features/<name>.sh` or
   `lib/features/lib/<name>/`.

No workflow file changes are needed — the matrix is dynamic.

## Troubleshooting

### "My PR built feature X but I didn't touch it"

Check `tests/changed_features.sh`'s mapping rules — likely your diff
touched a foundational path (`Dockerfile`, `lib/base/**`,
`lib/runtime/**`, `tests/framework/**`, or `crates/**`), which forces the
full merge-tier cluster as a defensive fallback. The `detect-changes` job
log shows the diff and emits `mode=full` when this happens.

### "My PR didn't build any features but should have"

The reverse case: your diff touched a path the mapping doesn't recognize.
Check `tests/unit/changed_features.sh` for the canonical test cases and
add coverage for the missed path. If the path *shouldn't* trigger a
build (pure docs / config change), no action needed — the skip is correct.

### "Cache-hit rate dropped to 0%"

Common causes:

- A `Dockerfile` change invalidated all subsequent layers — expected.
- The cache key changed (e.g., bumping a `*_VERSION` env in
  `lib/features/<X>.sh` invalidates the X layer and everything after).
- The cache scope name was edited — first run after a rename is always a
  cold start.

### "A PR's matrix is empty"

This is correct behavior for docs-only PRs. The summary job emits
`mode=skip` and passes immediately.

## Workflow files

- [`.github/workflows/test-pr.yml`](../../.github/workflows/test-pr.yml) — PR tier
- [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) — merge tier
- [`.github/workflows/evidence-run.yml`](../../.github/workflows/evidence-run.yml) — evidence runs (#478)
- `.github/workflows/test-weekly.yml` — planned (#408-B)
- `.github/workflows/test-monthly.yml` — planned (#408-C)
- `.github/workflows/quarterly-review.yml` — extends for #408-D

## Related documentation

- [Review Cadence](review-cadence.md) — quarterly tracking issue + ad-hoc sweeps
- [Automated Releases](automated-releases.md) — weekly auto-patch system
- [Build Metrics](../ci/build-metrics.md) — image-size baselines
- [Testing](../development/testing.md) — test framework conventions
