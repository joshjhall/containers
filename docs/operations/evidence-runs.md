# Evidence runs: ingestion contract

This document is the contract for shipping `TestEntry`-shaped evidence
rows from this repo's CI into the sibling
[`joshjhall/containers-db`](https://github.com/joshjhall/containers-db)
catalog. It is the single source of truth for the producer/consumer
boundary; if this doc and the running code disagree, the code wins and
the disagreement is a doc bug to file.

Background lives in design tracker
[#473](https://github.com/joshjhall/containers/issues/473) and the
producer-side work in [#476](https://github.com/joshjhall/containers/issues/476)
(merged PR [#479](https://github.com/joshjhall/containers/pull/479)).

## Overview

```text
+----------------------------+         +-------------------------------+
|  joshjhall/containers      |  PR     |  joshjhall/containers-db      |
|                            |  ----->  |                              |
|  .github/workflows/        |         |  tools/<tool>/versions/<v>.json
|    evidence-run.yml        |         |    tested[]   <-- the row     |
|       |                    |         |                               |
|       v                    |         |  schema/version.schema.json   |
|  bin/ingest-evidence.sh    |         |  validate / scan workflows    |
+----------------------------+         +-------------------------------+
```

The producer:

1. Pulls a hardened base image and resolves the `sha256:` digest.
2. Runs `luggage install <tool>@<version> --json-report` inside the
   image and captures the report.
3. Wraps the report + runner metadata into a `TestEntry`-shaped JSON
   row via `record-evidence`
   ([`crates/record-evidence/`](../../crates/record-evidence/)).
4. Hands the row to `bin/ingest-evidence.sh`, which opens a PR against
   containers-db that appends the row to the appropriate
   `tested[]` array.

The consumer:

- Validates the PR via its own
  [`validate.yml`](https://github.com/joshjhall/containers-db/blob/main/.github/workflows/validate.yml)
  (ajv-cli + semantic Rust validator).
- A maintainer reviews and merges. No auto-merge today — every
  evidence row crosses through review.

## Wire format

The row shape is defined by
[`schema/version.schema.json`](https://github.com/joshjhall/containers-db/blob/main/schema/version.schema.json)
in containers-db (the `tested[]` items). The producer emits it via
[`crates/record-evidence/src/lib.rs`](../../crates/record-evidence/src/lib.rs);
the field list lives there and is reproduced below for orientation
only — **if this list and the schema disagree, the schema wins.**

| Field              | Type                  | Required | Notes                                              |
| ------------------ | --------------------- | -------- | -------------------------------------------------- |
| `os`               | string                | yes      | distro slug (`debian`, `alpine`, `rhel`, …)        |
| `os_version`       | string (opt)          | no       | e.g. `12`, `3.21`                                  |
| `arch`             | string                | yes      | `amd64`, `arm64`, …                                |
| `tested_at`        | RFC 3339 string       | yes      | UTC; set by `record-evidence` at run time          |
| `ci_run`           | URL string (opt)      | no       | the producer workflow run                          |
| `result`           | `pass`/`fail`/`skip`  | yes      | derived from luggage report                        |
| `image_ref`        | string (opt)          | paired   | pull-spec without digest                           |
| `image_digest`     | `sha256:<64 hex>`     | paired   | content-addressed digest; must lowercase           |
| `duration_seconds` | number (opt)          | no       | wallclock of `luggage install`                     |
| `version_output`   | string (opt)          | no       | captured `<tool> --version` stdout                 |
| `error_class`      | enum (opt)            | no       | populated when `result == fail`                    |
| `dependencies`     | array (opt)           | no       | resolved system-dep versions; best-effort, pass rows |
| `notes`            | string (opt)          | no       | reserved for future maintainer-supplied annotation |

`image_ref` and `image_digest` are a paired requirement
(`dependentRequired` in the schema): both present or both absent. The
`error_class` enum mirrors `luggage::ErrorClass`
([`crates/luggage/src/error.rs`](../../crates/luggage/src/error.rs)).

### `dependencies` — captured system-dependency versions

`dependencies` records the concrete versions of the system packages a tool's
install was validated against (`gcc`, `libc6-dev`, `ca-certificates`, …), so a
"passed last month, fails today" install can be correlated with a base-image
toolchain bump instead of guessed at. Each element is an `InstalledDependency`:

| Field     | Type         | Notes                                                  |
| --------- | ------------ | ------------------------------------------------------ |
| `tool`    | string       | abstract catalog `Dependency.tool` id (e.g. `gcc`)     |
| `package` | string       | per-distro package name installed (e.g. `libc6-dev`)   |
| `version` | string (opt) | resolved version; omitted when the query found nothing |

It is captured **best-effort** and only on the success path of a
`luggage install --json-report` run: luggage queries the host package manager
(`dpkg-query -W` / `apk info -v` / `rpm -q`) after installing the
dependencies. A failed query leaves that entry's `version` unset rather than
failing the install; skip, dry-run, and failure rows omit `dependencies`
entirely (`skip_serializing_if`).

The containers-db `TestEntry` schema carries the matching `InstalledDependency`
`$def` + optional `dependencies[]`
([containers-db#26](https://github.com/joshjhall/containers-db/issues/26),
mirroring [containers-db#14](https://github.com/joshjhall/containers-db/issues/14)),
so a row carrying `dependencies` validates and ingests normally.

## Arch matrix (native vs emulated)

`evidence-run.yml` produces one row per `(tool, version, tuple)` leg, and the
**arch** half of the tuple drives how that leg builds and runs. The recorded
`arch` is always the third tuple token (`debian-12-amd64` → `amd64`), split out
by the `Derive tuple coordinates` step — there is no hardcoded `x86_64`
anywhere. Each leg additionally carries three build-plumbing companions, set
together in the `setup` job (`arch_plumbing`): `runtime`, `runner`, and
`rust_target`.

| `runtime`  | `runner`           | `docker run`               | binary build                        |
| ---------- | ------------------ | -------------------------- | ----------------------------------- |
| `native`   | arch-matched       | no `--platform`            | compiled on an arch-matched runner  |
| `emulated` | `ubuntu-latest`    | `--platform linux/<arch>`  | **cross-compiled** for the leg arch |

An **emulated** leg adds a `docker/setup-qemu-action@v3` step (registers binfmt
handlers) so an amd64 runner can run a foreign-arch container.

**The `luggage` binary is built for the container arch in both modes.** It is
mounted into the base image and executed *inside* it (`luggage install …`), so
it must match the container's architecture regardless of where the build ran.
That means an emulated arm64 leg on an amd64 host **cross-compiles**
`aarch64-unknown-linux-musl` (via `gcc-aarch64-linux-gnu` +
`CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER`); a native arm64 leg compiles
the same target natively. luggage's pure-Rust TLS (rustls) keeps the
cross-compile free of OpenSSL cross headers.

### `duration_seconds` under emulation

QEMU user-mode emulation inflates wallclock by a large, variable factor. A
`duration_seconds` recorded on an **emulated** leg is **not comparable** to a
native one and must never back a performance or cross-arch timing claim — treat
it as indicative only. This compounds the field's existing volatility: per
[Merge policy](#merge-policy), `duration_seconds` is a volatile-only field that
never alone triggers a re-ingest, so an emulated timing drift produces no
catalog churn.

### Push and PR matrix (catalog-derived)

The `setup` job builds the push-triggered matrix from the vendored catalog and
the base-images tree with
[`bin/lib/evidence-matrix.sh`](../../bin/lib/evidence-matrix.sh) (#1111):

```text
newest patch of each minor, minimum_recommended floor and up
  x  support_matrix `supported` tuples  ∩  base-images/<os>/<osv>/<arch>/Dockerfile
  -  cells that already have a passing tested[] row in published containers-db
  -  cells whose newest failing row is inside the fail cooldown (default 7 days)
  ordered: never-tested cells, then stale-failure retries; oldest version first in each
```

- **Evidence from published containers-db** (#1319). Versions and claims come
  from the vendored catalog. The passing `tested[]` rows that remove a cell come
  from a `joshjhall/containers-db` checkout (`_db`), plus the `tools/` tree of
  each still-open `evidence/batch/*` PR. The previous run's ingest PR is often
  still waiting to auto-merge when the next push resolves its matrix. The
  sources are passed colon-separated as `EVIDENCE_TESTED_SOURCE`, and their
  rows are unioned. Only same-repo PRs authored by the ingest identity and
  under 24 hours old count (`evidence_open_prs`). A branch name alone can come
  from any fork, and a stuck PR must not hide its cells forever. The vendored
  snapshot never receives `tested[]` rows, and the drift gate ignores them, so
  judging against it made every push re-test the same oldest ~200 cells. If
  any source can't be fetched, or holds no readable version files, the step
  fails. It does not fall back to "everything pending". This is stricter than `luggage reconcile` (below), which warns and
  uses local rows. A wrong report only costs a warning. A wrong matrix costs up
  to 200 runners re-testing covered cells. With the variable unset (unit tests,
  local runs), the vendored `tested[]` decides.
- **Newest patch per minor**, because that's what `RUST_VERSION=X.Y` installs.
  Superseded patches stay installable but aren't re-tested.
- **Pending only.** Re-running a covered cell is a no-op at ingest, and the full
  product (18 versions × 18 tuples = 324) exceeds GitHub's 256-job matrix cap.
  A base-image rebuild re-evidences its tuple separately
  ([`dispatch-evidence-for-tuple.sh`](../../bin/dispatch-evidence-for-tuple.sh)).
- **Failing cells cool down, then retry last** (#1326). Only a passing row
  covers a cell, so without a policy a tuple that always fails (a broken
  toolchain/distro combination) came back on every push. It used a runner each
  time, re-commented on its auto-issue
  ([Failure surfacing](#failure-surfacing--auto-issue-on-a-fail-row)), and took
  cap budget ahead of untested newer versions. The policy:
  - A cell whose **newest** `fail` row has a `tested_at` within
    `EVIDENCE_FAIL_COOLDOWN_DAYS` (default **7**) is evidenced (failed), not
    pending. The auto-issue already tracks it, and a retry inside the window
    would just fail again.
  - After the cooldown the cell is pending again, because a fix may have landed.
    It sorts **after every never-tested cell**, so a persistent failure only
    uses budget that untested work leaves free. A retry that fails again
    refreshes the row's `tested_at` at ingest (see
    [Merge policy](#merge-policy)), which restarts the cooldown. So a
    persistent failure costs one runner per window, not one per push.
  - A passing row always wins. A fail row with a missing or unparsable
    `tested_at` counts as stale, so it is retried last but is never hidden.
    Parsable means `YYYY-MM-DDTHH:MM:SS`, optional fractional seconds, then
    `Z` or a `+HH:MM`/`-HH:MM` offset from `-12:00` to `+14:00` (converted
    to UTC). `record-evidence` always writes `Z` with nanoseconds.
    Lowercase `z`, `+HHMM`, an out-of-range offset such as `+99:99`, and bare
    dates are unparsable. The same parse decides "newer" at ingest.
  - The cooldown is keyed by tuple, not by image digest. A base-image rebuild
    (new digest) still re-evidences its tuple right away through
    `dispatch-evidence-for-tuple.sh`, which dispatches whenever the newest
    *passing* digest differs and does not read this matrix or its cooldown.
    So a failing cell on a rebuilt image is retried at rebuild time, not
    after the window.

  `EVIDENCE_FAIL_COOLDOWN_DAYS=0` retries every failure on the next push (still
  ordered last). Tests pin the clock with `EVIDENCE_NOW` (epoch seconds). The
  same rule applies to vendored `tested[]` when no published source is set.
- **Capped at 200 per run, oldest versions first** (never-tested cells before
  failure retries), so a backlog (a new platform, or the 1.82+ backfill) drains
  over successive pushes, floor first.
- **Published images only.** A tuple is available only if
  `ghcr.io/.../base-<tuple>:latest` exists. On the merge that adds a tuple, the
  matrix runs alongside the base-image publish; without this, the first run
  queued cells for images that didn't exist yet (#1113: 74 cells failed at
  `Resolve base image digest`). Those tuples stay pending and run once
  published.
- **Nothing pending** → `has_cells=false` and the evidence job is skipped (an
  empty matrix is a hard error in Actions).
- **Pull requests** dry-run only the first pending cell in that order. That
  proves the pipeline still works without re-evidencing the backlog on every PR.

Both arches run natively: arm64 on `ubuntu-24.04-arm`, amd64 on
`ubuntu-latest`. The supported platform set lives in
[`docs/reference/supported-platforms.md`](../reference/supported-platforms.md).

### Ingest: one PR per run

Cells only install, record, and upload their row (an envelope adding
`tool`/`version` to the TestEntry, as artifact
`evidence-row-<tool>-<version>-<tuple>`). The **`collect`** job then:

1. downloads every row from the run,
1. merges each into its version file in one containers-db checkout with the
   shared dedup policy ([`bin/lib/evidence-merge.sh`](../../bin/lib/evidence-merge.sh)),
1. validates once, and opens **one** PR on `evidence/batch/<run_id>` with
   **auto-merge** enabled ([`bin/ingest-evidence-batch.sh`](../../bin/ingest-evidence-batch.sh)),
1. files **one** tracking issue listing the run's `fail` rows, if any.

It runs even when cells failed, since a fail row is evidence too. Rows already
recorded make it a no-op: no PR. Before this, every cell opened its own PR and
its own issue, so one push could open 200 PRs that conflicted on shared version
files, and one luggage bug filed dozens of duplicate issues.

**Cells install against the vendored catalog** (`crates/luggage/testdata/catalog`,
the one luggage was built and shipped with), not containers-db `main`.
Reading `main` raced every DB change that needed a matching luggage change: in
the window between the two merges, every cell recorded a false failure
(#1164's `util_linux`). containers-db is only the ingest target.

## Dispatching evidence on a version bump

When the auto-patch pipeline bumps a luggage-managed tool's `ARG <TOOL>_VERSION`
on `main`, the post-merge job runs
[`bin/dispatch-evidence.sh`](../../bin/dispatch-evidence.sh). Rather than firing
one hardcoded tuple, the dispatcher **enumerates the matrix**: it reads the new
version's `support_matrix` from containers-db and dispatches one
`evidence-run.yml` per cell in

```text
support_matrix `supported` cells  ∩  available published base tuples
```

so a bump evidences every cell the version actually claims — never silently
shipping unverified `supported` claims (#645).

**Available-tuples source of truth.** The "available" half of the intersection
is the local `base-images/<os>/<os_version>/<arch>/Dockerfile` tree — the same
canonical set [`base-images/README.md`](../../base-images/README.md) defines and
[`build-base-images.yml`](../../.github/workflows/build-base-images.yml) builds
from. A `support_matrix` row with no `os_version` (a wildcard claim) is realized
through whichever concrete available tuples it covers; a claim for a tuple with
no published base image simply drops out of the intersection.

**Only runnable cells fire.** A claimed tuple with no base image drops out of
the intersection, so the dispatcher fires exactly the cells that can actually
run. An empty intersection logs `no supported tuples available` and dispatches
nothing, exiting cleanly rather than erroring.

**Cross-repo deferral + idempotency still apply.** If containers-db has not yet
published `tools/<slug>/versions/<version>.json`, the dispatcher logs a clean
defer and skips the tool (the hourly containers-db scanner adds the version
independently, and the next trigger picks it up). The ingest layer's
`(os, os_version, arch, image_digest)` dedup key keeps re-runs idempotent end to
end — see [Merge policy](#merge-policy).

**`EVIDENCE_TUPLE` is a manual single-tuple override.** Left unset (the
post-merge default), the dispatcher enumerates the intersection above. Set to a
single `<os>-<os_version>-<arch>` slug, it bypasses the intersection and
dispatches only that tuple — for operators driving a one-off evidence run by
hand.

## Transport choice — PR-bot

The producer opens a PR against `joshjhall/containers-db`. It does not
write directly to `main` and does not stage rows through an external
artifact store.

Considered:

- **PR-bot.** Selected. Matches the existing scanner convention in
  containers-db
  ([`.github/workflows/scan.yml`](https://github.com/joshjhall/containers-db/blob/main/.github/workflows/scan.yml)),
  reuses containers-db's existing `validate.yml` as the pre-merge
  check, and keeps a per-row review trail. Cheap to extend with
  auto-merge later if reviewer fatigue justifies it.
- **GitHub API direct write to main.** Rejected. Loses the review
  trail, and the consumer's semantic validator (cross-file rules)
  only runs on PRs today — a bad row would land on `main` before
  catching the regression. Reasonable to revisit once row signing
  and auto-validation close that gap.
- **Artifact + poll.** Rejected. Adds a third moving piece (artifact
  store, poller) without paying back at current volume. Worth
  revisiting only if cross-repo auth becomes a per-org chokepoint.

The decision is reversible — the wire format is identical across
transports, so swapping out the back-end is a script-replacement
exercise.

## Repo boundary

- **Producer:** `joshjhall/containers` — this repo. CI runs from
  [`.github/workflows/evidence-run.yml`](../../.github/workflows/evidence-run.yml).
- **Consumer:** `joshjhall/containers-db` — sibling repo with
  `tools/<tool>/versions/<v>.json` files. The producer never retains a
  long-lived checkout; the workflow clones the consumer fresh per run
  via `bin/ingest-evidence.sh`.
- **Trust direction:** producer → consumer is write; consumer →
  producer is none. The producer reads consumer state for two
  decisions only: "does the target version file exist?" (the
  evidence-run / dispatch precondition) and, for the base-image
  rebuild trigger, "is the newest passing `tested[]` digest for this
  cell already the one we just built?" (see
  [Re-running evidence on a rebuilt base image](#re-running-evidence-on-a-rebuilt-base-image)).
  Both are read-only existence/equality checks against published
  catalog files — the producer never writes consumer state outside the
  PR transport, and never lets consumer data influence what evidence a
  run *records*.

## Auth model

The transport requires write access to `joshjhall/containers-db`. The
GitHub-issued `GITHUB_TOKEN` does not span repositories, so a
caller-supplied credential is needed.

**Today: fine-grained Personal Access Token in
`secrets.CONTAINERS_DB_PAT`.** Required scopes:

- Repository access: only `joshjhall/containers-db`.
- Permissions: `Contents: Read and write`,
  `Pull requests: Read and write`, `Metadata: Read-only` (the latter
  is implicit but listed for completeness).

The workflow reads this secret only in the non-dry-run path; a
missing secret fails the run with a banner pointing at this doc.

**Future: GitHub App.** Recommended once any of (rotation pain,
auditability needs, multiple producers) is hit. Use
[`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)
to mint a short-lived token from a stored app credential. The
contract shape is unchanged — the script reads `GH_TOKEN` either way.

### Rotation procedure

1. Generate a new fine-grained PAT in the producing user's settings
   with the scopes above and an expiration ≤90 days.
2. Update the `CONTAINERS_DB_PAT` repo secret on
   `joshjhall/containers` (Settings → Secrets and variables →
   Actions).
3. Re-run `evidence-run.yml` once with `dry_run=true` to verify the
   non-PAT path still works, then once with `dry_run=false` to verify
   the new credential.
4. Revoke the previous PAT.

If `gh` reports HTTP 401 in a workflow run, the PAT is the most
likely cause — start with rotation. The script does not retry past
the second 401 (the auth header doesn't change between retries).

## Merge policy

Default: **append**. The transport never deletes existing rows in
`tested[]`. The ingest is idempotent end-to-end: re-running it with
unchanged inputs produces no commit, no branch, and no PR (see below).

Dedup key: `(os, os_version, arch, image_digest)`. When the new row
matches an existing row on all four, behavior depends on whether
anything *meaningful* changed:

- **Meaningful change** (different `result`, `error_class`,
  `version_output`, …) → the existing row is **replaced** by the new
  row. The fresh answer supersedes the stale one.
- **Volatile-only change** (only `tested_at`, `ci_run`, and/or
  `duration_seconds` differ) → **no-op**. The existing row is left
  untouched and the ingest exits 0 without committing, pushing, or
  opening a PR. Re-running the identical image on the identical tuple
  reproduces the same result deterministically, so a fresher timestamp
  alone carries no new evidence — and would otherwise churn a
  review-required PR on every `push → main`.
- **Exception: a repeated `fail`** (#1326) → **replaced**, even when only
  volatile fields differ. A fail row's `tested_at` records the last attempt,
  and the matrix's fail cooldown keys on it
  ([Push and PR matrix](#push-and-pr-matrix-catalog-derived)). A no-op would
  freeze the first failure's timestamp, so after one cooldown the cell would
  retry on every push. The refresh happens only when the new `tested_at` is
  newer; an identical or older fail row (a saved row re-ingested late) is
  still a no-op, so the timestamp never moves backwards. The row is updated in
  place, keeping `tested[]` order. The cost is at most one row update per
  failing cell per cooldown window, carried in the run's batched ingest PR.

Rationale:

- Different `image_digest` = different base image build = independent
  evidence point; keep both for history. Freshness from patched base
  images therefore rides on the **digest** — a rebuilt image is
  content-addressed to a new digest, yielding a new appended row — not
  on re-timestamping a byte-identical image.
- Same `image_digest` + same tuple + same meaningful fields = "have we
  already recorded this exact reproducible run?". We don't carry
  duplicates of it.

A row missing both `image_ref` and `image_digest` is allowed by the
schema (paired-absent), but in practice the producer always sets both
— this branch exists only so the dedup key is well-defined for
hand-crafted fixture rows.

### Re-running evidence on a rebuilt base image

The rationale above asserts that freshness rides on the digest — a
patched base image is content-addressed to a new digest, yielding a new
appended row. This section is the mechanism that makes that true.

**Trigger.** [`build-base-images.yml`](../../.github/workflows/build-base-images.yml),
after it publishes and signs a new image for a tuple, runs
[`bin/dispatch-evidence-for-tuple.sh`](../../bin/dispatch-evidence-for-tuple.sh)
for that tuple. The helper dispatches
[`evidence-run.yml`](../../.github/workflows/evidence-run.yml) (via
`workflow_dispatch`) for each luggage-managed tool that claims the tuple
`supported` in its `support_matrix`. This is **build-time dispatch**,
chosen over a scheduled reconciler because the build job already holds
the freshly published digest; a cron job would have to re-discover it by
polling the registry. The step is best-effort (`continue-on-error: true`)
— a dispatch hiccup never fails the base-image build. It needs a
cross-repo-capable token: `GITHUB_TOKEN` cannot trigger another
workflow, so the step reuses `secrets.AUTO_PATCH_TOKEN` (the same
credential the auto-patch post-merge dispatch uses).

**Ordering.** Dispatch fires only on a publish (`steps.gate.outputs.publish == 'true'`),
i.e. after the image is pushed and signed; PR builds never push a digest
and never dispatch. Evidence-run then re-pulls the tag and re-resolves
the digest with `docker inspect`, so it always records the digest of the
artifact actually exercised — the dispatch-time digest is never
forwarded.

**Two-layer idempotency.** A rebuild that produces a byte-identical
image (same digest) must fire nothing; a CVE-patch rebuild (new digest)
must fire exactly one run:

- *Dispatch layer.* The helper reads the newest **passing** `tested[]`
  digest for the cell and skips the tool when it already equals the new
  digest. So an identical rebuild — or a no-op re-run of the build job —
  dispatches no workflow at all. A tool with no prior evidence
  (`tested[]` empty, as the pilot catalog ships) always dispatches.
- *Ingest layer.* Even a redundant dispatch no-ops on the
  `(os, os_version, arch, image_digest)` dedup key in
  `bin/ingest-evidence.sh` — no commit, branch, or PR. Belt and
  suspenders for a race where evidence landed via another path between
  dispatch and ingest.

**Deferral.** Evidence-run hard-fails if the sibling containers-db lacks
`tools/<tool>/versions/<version>.json`. The helper checks first and logs
a clean defer rather than dispatching a doomed run; the sibling scanner
publishes the version independently, and the next rebuild picks it up.

**Scope.** Only luggage-managed tools (the helper's `LUGGAGE_TOOLS`
table) that claim the rebuilt tuple `supported` are dispatched — one
`evidence-run.yml` dispatch per such tool.

Ordering: rows are appended in arrival order; no sort is enforced.
The consumer's CI does not depend on order, and chronological order
is not stable across multiple producers anyway.

## Failure modes

1. **Stale image digest.**
   The workflow re-resolves the digest via `docker inspect` immediately
   before the install run, so the row records the digest actually
   exercised. Drift across runs (e.g., the `:latest` tag moved between
   two runs) is data — both rows will be kept under the dedup key
   above. No mitigation needed beyond "always set the digest from
   inspect output, never from a configuration file." A *rebuild* to a
   new digest is handled actively, not passively — see
   [Re-running evidence on a rebuilt base image](#re-running-evidence-on-a-rebuilt-base-image).

1. **Schema bump mid-flight.**
   `bin/ingest-evidence.sh` runs `just db-validate-tool <tool>` against
   the augmented file *before* committing. If the row no longer
   validates (consumer bumped the schema between row production and
   ingest), the script exits non-zero and no PR is opened. The
   producer's next run will pick up the new schema via the fresh clone.

1. **Auth / credential rotation.**
   PAT expiry surfaces as a `gh` HTTP 401 during push or PR open. The
   workflow fails loudly with a pointer to the
   [Rotation procedure](#rotation-procedure) above. Belt-and-suspenders:
   set the PAT's expiration ≤90 days and audit `Settings → Secrets`
   monthly.

1. **Duplicate / re-run row.**
   Handled by the dedup key in [Merge policy](#merge-policy). Re-running
   a workflow against an unchanged image digest is a clean no-op: the
   ingest detects nothing meaningful changed, logs `nothing to ingest`,
   and exits 0 without committing, pushing, or opening a duplicate PR.
   Operators can re-run a flaky workflow freely without bloating the
   file or spawning redundant PRs.

   Workflow runs ingest every row as **one batched PR per run** (see
   [Ingest: one PR per run](#ingest-one-pr-per-run)), auto-merged, so
   the queue never builds up. The manual single-row path
   (`bin/ingest-evidence.sh`) keeps a stable branch per cell,
   `evidence/<tool>/<version>/<tuple>`: it force-pushes that branch and
   updates an already-open PR instead of opening another.

1. **Network flake on push or PR open.**
   The script retries `git push` and `gh pr create` up to 3 times with
   exponential backoff (2s, 4s). Final failure exits non-zero; the
   workflow surfaces `gh`'s stderr verbatim so the next operator can
   read the upstream error.

1. **Validate workflow timeout on the consumer side.**
   Out of scope for the producer — if containers-db's `validate.yml`
   hangs, the PR sits open. Mitigation lives on the consumer side.

## Failure surfacing — auto-issue on a `fail` row

An evidence run intentionally **does not** fail the job when a `luggage install`
fails: luggage's `--json-report` writes a `result: fail` row, and recording that
row is the whole point of an evidence run (the install runs under `set +e`). The
verdict lives in the row's `result` field, with `error_class` set on failure.

That row flows into containers-db as evidence — but on its own it is quiet data a
reviewer might rubber-stamp. So on a **non-dry-run** leg, a `result: fail` row
opens or updates a tracking issue in **this** repo, matching the cadence tiers'
search-or-create convention (see
[`ci-tiers.md` § Auto-issue on failure](ci-tiers.md#auto-issue-on-failure)).

- **Title key** `(tool, version, tuple)` — e.g. `Evidence regression:
  rust@1.95.0 on debian-12-amd64`. The tuple encodes `os-os_version-arch`, so a
  re-failure on the same cell updates one issue while a different distro/arch
  opens its own. No duplicates.
- **Body** carries the run URL and the row's `error_class`; a re-failure adds a
  dated comment instead of a new issue.
- **Labels** `severity/high` + `type/bug` + `audit/regression`. The last is the
  cadence-tier vocabulary and is created on-the-fly (`gh label create --force`)
  so the step never fails on a missing label.
- **Scope** non-dry-run legs only. PR legs are forced to `dry_run=true` in the
  `setup` job, so they never file an issue — the step gates on
  `needs.setup.outputs.dry_run != 'true'`, which also keeps it fork-safe.
- **Auth** the default `GITHUB_TOKEN` (job-scoped `issues: write`); the issue is
  filed on `joshjhall/containers`, not the sibling db, so no PAT is involved.

## Known limitations

- **PR diffs are noisier than the row.** The ingest script uses `jq`
  to splice the new row into `tested[]`, which re-pretty-prints the
  whole file using `jq`'s formatting rules. Hand-formatted compact
  blocks (e.g. one-line `support_matrix` entries) get expanded into
  multi-line form. The reviewer still sees exactly one new row, but
  the diff stat overstates the change. Acceptable for the prototype
  surface; a non-reformatting JSON splicer (a small Rust helper or
  `dasel`) is the cleanup path once volume justifies it.

## Local development

The script is testable end-to-end locally with no PAT and no Docker.

```bash
# 1. Clone containers-db as a sibling so $CONTAINERS_DB resolves.
git clone https://github.com/joshjhall/containers-db ../containers-db

# 2. Emit the checked-in sample row and pipe it through the ingest
#    script in dry-run mode.
just evidence-row-stub | ./bin/ingest-evidence.sh \
    --row - \
    --db-path ../containers-db \
    --tool rust \
    --version 1.95.0 \
    --dry-run
```

The dry-run path stops after the local commit; inspect the resulting
branch with `git -C ../containers-db log -1 --stat`. `just
ingest-evidence` wraps the above with the fixture path baked in.

## Acceptance evidence (post-merge)

The end-to-end acceptance criterion for sub-issue C is one real PR
opened against containers-db, merged, and visible as a single row in
`tools/rust/versions/1.95.0.json`'s `tested[]`. To execute (maintainer
action):

1. Configure `CONTAINERS_DB_PAT` per [Auth model](#auth-model).
2. Trigger `evidence-run.yml` once via the Actions UI with
   `dry_run=false` (keep the other defaults).
3. Verify a PR appears at
   <https://github.com/joshjhall/containers-db/pulls> titled
   `feat(rust): record rust@1.95.0 evidence on debian-12-amd64 (pass)`.
4. Merge that PR, refresh the version file, and confirm the row is
   present.

Once that's done, close
[#477](https://github.com/joshjhall/containers/issues/477) with a link
to the containers-db PR.

## Coverage reconciliation

Evidence runs *produce* `tested[]` rows; reconciliation *audits* them. A
version file carries two independent views of the same
`(os, os_version, arch)` cells:

- `support_matrix[]` — hand-authored **intent**. A row's `status` claims
  whether the tool runs on that cell.
- `tested[]` — machine-recorded **evidence**. A row with `result: "pass"`
  proves an install happened.

Nothing keeps the two in sync, so a `supported` claim can sit forever with
zero passing evidence — exactly the trust gap the evidence system exists to
close. `luggage reconcile` cross-checks them.

```bash
# Report mode (informational, always exits 0). Omit the tool to walk the
# whole catalog.
just reconcile rust
# or directly:
luggage reconcile rust --catalog ../containers-db
luggage reconcile rust@1.96.0 --json --catalog ../containers-db

# Gate mode (opt-in): exit non-zero on an uncovered supported cell.
just reconcile-gate rust
```

### Where the evidence comes from

`--catalog` supplies the claims; the evidence is fetched from the published
containers-db first (`--published-base`, default containers-db `main` raw
files), one version file at a time, and only its `tested[]` is used. The
vendored catalog's `tested[]` is deliberately *not* kept in lockstep with
containers-db (the drift gate ignores it — every merged evidence PR would
otherwise red-line this repo), so judging against it would report gaps
upstream has already closed. Each version reports its origin:

| Origin | Meaning | Findings |
|---|---|---|
| `published` | Fetched from containers-db. | Judged normally; `--gate` blocks. |
| `local (not yet published)` | containers-db answered 404 — no entry yet. That is an answer, not an outage. | Judged normally; `--gate` blocks. |
| `local fallback, possibly stale` | containers-db unreachable (network error, 5xx, unparsable body), or `--offline`. The local evidence is used. | Reported as **stale-evidence warnings** naming the newest local `tested_at`; never gate failures. |

The fallback is what keeps an offline or air-gapped environment usable:
evidence there may be stale and still acceptable, so it is surfaced with its
age for a human to judge rather than failing the run.

### The coverage contract

A `tested[]` row counts as evidence for a `support_matrix` cell when it has
`result: "pass"` and matches the cell on `(os, arch)` plus `os_version`,
using the same wildcard rule the resolver uses: a `support_matrix` row with no
`os_version` is satisfied by a passing row on **any** version of that `os`.
The newest matching row's `tested_at` is reported as the cell's freshness.
Per-cell classification:

| Claimed `status` | Passing evidence row? | Classification | Gate |
| ---------------- | --------------------- | -------------- | ---- |
| `supported`      | yes                   | **covered** (with freshness) | pass |
| `supported`      | no                    | **uncovered** | **fail** |
| `unsupported`    | yes                   | **contradiction** — claim says "won't run", evidence says it did | **fail** |
| `unsupported`    | no                    | no evidence needed | pass |
| `untested`       | yes                   | **promotable** — candidate for upgrade to `supported` | pass (info) |
| `untested`       | no                    | no evidence needed | pass |

Only **uncovered** and **contradiction** fail `--gate`. Freshness is reported,
never gated.

### Report vs gate in CI

`evidence-run.yml` runs a self-contained `reconcile` job in **report mode**
against the vendored testdata catalog (`crates/luggage/testdata/catalog`) on
every push/PR. It is hermetic — no base image, no containers-db clone — and
non-blocking: it surfaces the claim-vs-evidence gap without failing the build.

Gate mode is **intentionally not** a required check yet. The pilot produces
only `debian-12-amd64` evidence and none is merged, so `--gate` over the real
catalog would be red on day one. The CLI fully implements the gate (covered by
the `luggage` CLI tests) and `just reconcile-gate` is the opt-in path; promote
the CI job to `--gate` once the base-image matrix and merged evidence cover the
claimed cells. See
[#639](https://github.com/joshjhall/containers/issues/639).

## Related

- [#473](https://github.com/joshjhall/containers/issues/473) — design tracker
- [#476](https://github.com/joshjhall/containers/issues/476) /
  [#479](https://github.com/joshjhall/containers/pull/479) — producer side (B)
- [#478](https://github.com/joshjhall/containers/issues/478) — workflow scheduling (D)
- [#639](https://github.com/joshjhall/containers/issues/639) — coverage reconciliation (this section)
- [base-images/README.md](../../base-images/README.md) — how the base images this consumes are built and signed
- [docs/operations/ci-tiers.md](ci-tiers.md) — the broader CI cadence story; evidence runs are dispatch-only today
- [containers-db#14](https://github.com/joshjhall/containers-db/issues/14) — schema extension that enabled this work
