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
| Nightly / RC | Cron daily 05:00 UTC (`ci.yml`), 05:30 UTC (evidence); `v*` tags | <1 h | Full rust-test OS matrix; full pending evidence matrix | Implemented (#1593) |
| Evidence  | `pull_request` (sampled) + `push` → main, nightly, `v*` tags (full) | <30 min (PR, no source build) | Every pending (tool × version × tuple) cell; a PR runs one per (tool × method kind × libc) | Implemented (#478, #1593) |

Promotion criteria are unidirectional — passing a faster tier is a prereq
for letting code reach the next slower tier, but a failure at a slower tier
does not block ongoing work (the regression opens an issue instead). Evidence
runs are off to the side of this chain: they don't gate merges, they record
what a published base image actually does when a tool is installed onto it.

The evidence tier records per-tool installs against signed base images, with
results landing in `joshjhall/containers-db`. It is path-scoped on PRs and
main pushes, and also runs nightly and on `v*` tags (#1593) — see the [Evidence runs](#evidence-runs) section below and
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
>
> **The label takes effect as soon as it is added (#1099)** — the workflow
> triggers on `labeled`, so adding `ci/full-build` to an already-open PR starts
> the tier immediately; no empty commit or close/reopen is needed. (Re-running
> an old run does *not* work: a re-run replays its original event payload,
> whose label list predates the label.) Removing the label does not cancel a
> run already in flight.

### CI/CD Pipeline concurrency

`ci.yml` cancels superseded PR runs (#1560): `pull_request` runs share one
group per PR (`ci-pr-<PR number>`) with `cancel-in-progress`, so a review-fix
push frees the runner slot the previous head's run was holding. Every other
event — pushes to `main`/`v5`/`auto-patch/**`, tags, `workflow_dispatch` — gets
a run-unique group (`ci-run-<run_id>`) and is never cancelled. A shared
per-ref group would not be enough: GitHub displaces a *pending* run when a
newer one joins its group even with `cancel-in-progress: false`, and release
and auto-patch depend on those results. `test-pr.yml` has its own group (below);
`evidence-run.yml` deliberately never cancels. Guarded by
`tests/unit/ci-concurrency.sh`.

### Label events and concurrency

GitHub cannot filter `labeled` by label name, so **every** label add creates a
`test-pr.yml` run. The workflow tells the two kinds apart:

- **Relevant** — `opened` / `synchronize` / `reopened`, or `labeled` with
  `ci/full-build`. These share a per-PR concurrency group
  (`test-pr-<PR number>`) with `cancel-in-progress`, so a push and a label add
  close together build the feature matrix once, not twice.
- **Irrelevant** — `labeled` with any other label (e.g. `status/pr-pending`,
  which `/workflow:ship-issue` adds at PR open). `detect-changes` and
  `build-feature` are skipped, and `PR Tier` **mirrors** the newest other
  non-cancelled `PR Tier` check run on the same head SHA. Because `PR Tier` is
  required, a plain skipped (= success) run here would become the newest check
  on the commit and turn a failed full build green on an unrelated label — the
  #854/#909 "green on no evidence" class. The mirror fails closed: anything but
  a completed `success`/`skipped`/`neutral` verdict (a failure, a still-running
  run, no prior run, or a `gh api` error) reports failure. Irrelevant runs
  never cancel; they queue behind the in-flight run in the same group, so the
  verdict they mirror has normally finished.

Residuals — all fail closed (a false red, never a false green):

- GitHub keeps at most one *pending* run per group and cancels the older one.
  A queued irrelevant run displaced by a newer event is harmless (the newer run
  reports, and the mirror ignores `cancelled` check runs). The reverse — a
  label add landing in the few seconds a just-pushed run is still pending —
  displaces that run, and the mirror then finds no verdict on the new SHA and
  fails. Recover by pushing again or re-running the cancelled run's workflow.
- If the mirror reads a still-running verdict (a race the queueing mostly
  prevents), it fails; re-run that `PR Tier` once the real run finishes.

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
   for branch protection. That rollup is the designated required context on
   `main` (#904), alongside `Run Tests` — see
   [`.github/required-checks.txt`](../../.github/required-checks.txt). Because
   it is required, `pr-tier` must keep reporting on **every** PR: it runs
   `if: always()` and exits 0 when detect-changes returns `skip`, so a docs-only
   PR reports success rather than reporting nothing. Preserve that property when
   editing this job — a required context that never reports blocks `main`.

   The **converse** property is equally load-bearing and easy to break while
   preserving the first: `pr-tier` must report **failure** whenever the tier did
   not actually certify the PR. It therefore gates on
   `needs.detect-changes.result` before reading anything else (#909) — a failed
   `detect-changes` leaves `mode` empty and `build-feature` `skipped`, which
   would otherwise read as a healthy nothing-to-build and report green over an
   empty build. Reporting green on no evidence is the #854 failure class, one
   hop upstream. Both directions are covered offline by
   [`tests/unit/required-checks-pr-tier.sh`](../../tests/unit/required-checks-pr-tier.sh), which
   extracts this job's run block and executes it across the upstream states.

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

### Rust tests: path-filtered OS matrix

`rust-test` runs on **ubuntu only** for a PR that touches no Rust input, and on
ubuntu + macOS + Windows for a PR touching `crates/`, `Cargo.toml`,
`Cargo.lock`, or `rust-toolchain*` (#1593). Push to main, `v*` tags, the nightly
schedule, and `workflow_dispatch` always run all three — `build` needs them.

[`bin/rust-test-matrix.sh`](../../bin/rust-test-matrix.sh), run by the
`rust-changes` job (`Rust Test Matrix`), picks the list and fails safe to the
full matrix if the diff cannot be computed. The per-OS legs carry a templated
name, so the required context is the always-running rollup
**`Rust Tests`** (`rust-test-result`), the same pattern as `PR Tier`. It passes
only when the detector and every leg it chose succeeded; a skipped or cancelled
leg is never a pass (#904). Tested by
[`tests/unit/required-checks-rust-tests.sh`](../../tests/unit/required-checks-rust-tests.sh).

## ci.yml job tiers

Audit of every `ci.yml` job (#1593): which ones gate a PR and which run only
after merge. PR-tier jobs are the required contexts or feed one.

| Job (`name:`)                                   | PR | main push | Nightly | `v*` tag | Why |
| ----------------------------------------------- | -- | --------- | ------- | -------- | --- |
| `test` (Run Tests)                              | ✅ diff-scoped lint | ✅ full | ✅ full | ✅ | Required context; the only shell/unit gate |
| `lint-ai-templates`                             | ✅ (no-op unless templates change) | ✅ | ✅ | ✅ | Seconds when skipped; cheap |
| `rust-changes` (Rust Test Matrix)               | ✅ | ✅ | ✅ | ✅ | Picks the rust-test OS list |
| `rust-test` (Rust Tests (stibbons) — *os*)      | ubuntu; all 3 if Rust paths change | all 3 | all 3 | all 3 | macOS/Windows are the scarce, 10×/2×-billed runners |
| `rust-test-result` (Rust Tests)                 | ✅ | ✅ | ✅ | ✅ | Required-context rollup |
| `rust-latest-stable`                            | ✅ (non-blocking) | ✅ | ✅ | ✅ | One ubuntu runner; early warning for the next MSRV bump |
| `build` (Build (Merge Tier))                    | — | ✅ | — | ✅ | Merge tier; the PR tier covers PRs |
| `integration-test`                              | — | ✅ | — | ✅ | Needs `build` |
| `debian-version-test`                           | — | ✅ | — | ✅ | Heavy; merge tier |
| `security-test`, `security-scan`                | — | ✅ | — | ✅ | Need `build`; `security-scan.yml` also runs weekly |
| `benchmark`                                     | — | ✅ (main only) | — | — | Trend data, not a gate |
| `release`                                       | — | — | — | ✅ | Publishes the release |

Nightly runs only the jobs without a `push`/`workflow_dispatch` gate; the
merge-tier jobs are deliberately left on push so a nightly is a cheap full
code-level sweep, not a second merge-tier build.

### Measured runner time

Median over the 20 most recent successful `ci.yml` PR runs before #1593
(per-job minutes, rounded up per job as GitHub bills them):

| | Before (measured) | After, non-Rust PR (projected) | After (measured, #1593's own PR run) |
| --- | --- | --- | --- |
| Runner-minutes | 19 | ~14 (12 ubuntu; macOS 3 and Windows 3 gone; +~2 for the detector and rollup jobs) | 15 (run 42692668810) |
| Billable minutes (macOS ×10, Windows ×2) | 49.5 | ~14 | 15 |
| macOS / Windows runner slots per PR | 2 | 0 | 0 |

"Projected" removes the macOS/Windows legs from the measured before-runs. The
measured column is one run, so treat it as a check on the projection. Re-take
the median over the first ~20 post-#1593 PR runs to replace both.

A PR that touches Rust inputs is unchanged. The raw-minute saving on a non-Rust
PR is about a quarter; the large saving is in the scarce macOS/Windows pools
(the ones that never got a runner on 2026-11-02) and in billable minutes. The
evidence median before #1593 was ~6 min over 15 PR runs, but a PR whose sample
included an alpine source-build cell paid ~115 min more — that cell now runs
only when the PR touches source-build code or that tool's catalog entry.

## Nightly / RC tier

**Status:** Implemented (#1593) as `schedule:` triggers on
[`ci.yml`](../../.github/workflows/ci.yml) (`0 5 * * *`) and
[`evidence-run.yml`](../../.github/workflows/evidence-run.yml) (`30 5 * * *`),
plus `v*` tag pushes on both.

What PRs no longer run, these do: the full rust-test OS matrix, and every
pending evidence cell with a real ingest (source builds included). A scheduled
run is never cancelled — `ci.yml` gives non-PR events a run-unique concurrency
group, and evidence-run serializes schedule and tag runs with main's group so
two ingests cannot open duplicate containers-db PRs. The evidence nightly is
self-limiting: once a cell's evidence lands it stops being pending, so a quiet
night has nothing to run.

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

### Integration suite coverage

The merge tier runs exactly the suites named in the `integration-test`
matrix — each variant's `test`, plus any space-separated `extra_suites` run
against the **same** published image. `extra_suites` is how a suite rides an
existing variant without a new build: `bindfs` and `setup_commands` run on
the `python-dev` leg (`INCLUDE_DEV_TOOLS=true` installs bindfs, cron, gh and
glab), and `mise` runs on the `polyglot` leg (`INCLUDE_MISE=true`). Every rider
also receives the published `minimal` image via `IMAGE_TO_TEST_MINIMAL`, which
the flag-absent checks (and `setup_commands`'s no-gh/glab cases) use instead
of a local build.

The `# @tier:` header is **not** what selects merge-tier suites — no workflow
calls `run_integration_tests.sh --tier=…` yet. So a suite outside the matrix
must say why, with a `# @ci:` marker under its `@tier` line, and must not
claim `merge`:

```bash
#!/usr/bin/env bash
# @tier: weekly
# @ci: local-only — mounts the host /var/run/docker.sock (#1027)
```

[`tests/unit/integration-ci-coverage.sh`](../../tests/unit/integration-ci-coverage.sh)
enforces both directions: a matrix suite declares `merge` and has no marker;
any other suite has a `scheduled` or `local-only` marker with a reason. A new
suite with no header defaults to `merge` and therefore fails until it is
either added to the matrix or marked.

| Disposition | Suites | Why |
| --- | --- | --- |
| Merge tier | `minimal`, `python_dev`, `node_dev`, `polyglot`, `bindfs`, `mise`, `setup_commands` | Covered by a published variant |
| Scheduled | `java_dev`, `r_dev`, `rust_golang`, `cloud_ops`, `production` | Variant parked for v5 (#508) |
| Scheduled | `android`, `kotlin`, `node_current`, `luggage_rust`, `claude_code_setup`, `claude_skills_agents` | Build images of their own that no merge-tier variant matches |
| Local-only | `docker_socket` | Mounts the host Docker socket into a root-started container |
| Local-only | `kubernetes_deployment` | Needs `--privileged` Docker-in-Docker for kind |

> **"Scheduled" does not mean "covered" today.** The weekly tier (#408-B) is
> not implemented, so a scheduled suite currently runs in **no** CI tier — the
> marker records that as a decision rather than an accident. Run one with
> `just test-integration-one <name>` when touching its area. Each suite's exact
> reason lives in its `@ci:` line.

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

The full matrix — every feature × every supported distro (Debian 12 / 13,
Alpine, RHEL/UBI, Ubuntu) × every arch (amd64, arm64) — runs Sundays at
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

Per [#473](https://github.com/joshjhall/containers/issues/473), "just enumerate"
beats sampling, so main, nightly, and tag runs take the exhaustive pending
matrix. A PR dry run proves only row shape and the luggage install path, so it
takes a sample (#1593). The PR and main-push triggers are **path-scoped** to
evidence sources (`crates/luggage/**`, `crates/record-evidence/**`,
`crates/containers-common/**`, `base-images/**`, the evidence `bin/` scripts, and
the workflow itself) so unrelated PRs don't pay the build-and-install cost:

| Trigger             | Matrix | Ingest behavior                                       |
| ------------------- | ------ | ----------------------------------------------------- |
| `pull_request` → main | Sample (below) | Dry-run: validate the row merges cleanly against the catalog schema. Fork-safe — no secrets. |
| `push` → main       | Every pending cell (cap 200) | Real ingest: open a PR against `joshjhall/containers-db` (requires the `CONTAINERS_DB_PAT` secret). |
| `schedule` (05:30 UTC) | Every pending cell (cap 200) | Real ingest, as push → main. |
| `push` → `v*` tag   | Every pending cell (cap 200) | Real ingest, as push → main (tags ignore `paths:`). |
| `workflow_dispatch` | Single ad-hoc leg from inputs | The `dry_run` input chooses validate vs. real ingest. |

**PR sample** (`evidence_pr_legs` in
[`bin/lib/evidence-matrix.sh`](../../bin/lib/evidence-matrix.sh)): the first
pending cell of each (tool × `method_kind` × libc) group — libc is musl for
alpine tuples, glibc otherwise. `source-build` cells (up to 3 h each; ~115 min
for node on alpine) are dropped unless `evidence_pr_source_build_scope` allows
them from the PR's changed files: every tool's when the PR touches
`crates/luggage/src/installer/methods/source_build*.rs`, or one tool's when the
PR touches `crates/luggage/testdata/catalog/tools/<tool>/`. If the PR's file
list cannot be read, no source build runs; main and nightly still cover it.

A `setup` job resolves the matrix (a single input-derived leg for dispatch, the
enumerated pilot legs for PR/push) and the effective dry-run flag, keeping the
`evidence` job body identical across events. A `concurrency` group serializes
runs on the same ref (tag runs share main's group) so two ingests can't race to
open duplicate PRs.

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
   The header alone does not put a suite in CI: either add it to the
   `integration-test` matrix (as a `test` or `extra_suites` entry) or add a
   `# @ci:` marker — see [Integration suite coverage](#integration-suite-coverage).
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
- [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) — code-level PR checks, merge tier, nightly/RC rust matrix
- [`.github/workflows/evidence-run.yml`](../../.github/workflows/evidence-run.yml) — evidence runs (#478; sampled on PRs, full nightly/RC, #1593)
- `.github/workflows/test-weekly.yml` — planned (#408-B)
- `.github/workflows/test-monthly.yml` — planned (#408-C)
- `.github/workflows/quarterly-review.yml` — extends for #408-D

## Related documentation

- [Review Cadence](review-cadence.md) — quarterly tracking issue + ad-hoc sweeps
- [Automated Releases](automated-releases.md) — weekly auto-patch system
- [Build Metrics](../ci/build-metrics.md) — image-size baselines
- [Testing](../development/testing.md) — test framework conventions
