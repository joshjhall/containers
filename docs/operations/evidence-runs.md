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
| `notes`            | string (opt)          | no       | reserved for future maintainer-supplied annotation |

`image_ref` and `image_digest` are a paired requirement
(`dependentRequired` in the schema): both present or both absent. The
`error_class` enum mirrors `luggage::ErrorClass`
([`crates/luggage/src/error.rs`](../../crates/luggage/src/error.rs)).

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
  producer is none. The producer never reads consumer state for any
  decision other than "does the target version file exist?".

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
`tested[]`.

Dedup key: `(os, os_version, arch, image_digest)`. When the new row
matches an existing row on all four, the existing row is **replaced**
by the new row. Rationale:

- Different `image_digest` = different base image build = independent
  evidence point; keep both for history.
- Same `image_digest` + same tuple = the row is "have we tested this
  exact image on this exact tuple recently?". The fresh answer
  supersedes the stale answer; we don't carry duplicates of the same
  reproducible run.

A row missing both `image_ref` and `image_digest` is allowed by the
schema (paired-absent), but in practice the producer always sets both
— this branch exists only so the dedup key is well-defined for
hand-crafted fixture rows.

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
   inspect output, never from a configuration file."

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

1. **Duplicate row.**
   Handled by the dedup key in [Merge policy](#merge-policy). Operators
   can land the same row twice (re-running a flaky workflow) without
   bloating the file.

1. **Network flake on push or PR open.**
   The script retries `git push` and `gh pr create` up to 3 times with
   exponential backoff (2s, 4s). Final failure exits non-zero; the
   workflow surfaces `gh`'s stderr verbatim so the next operator can
   read the upstream error.

1. **Validate workflow timeout on the consumer side.**
   Out of scope for the producer — if containers-db's `validate.yml`
   hangs, the PR sits open. Mitigation lives on the consumer side.

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

## Related

- [#473](https://github.com/joshjhall/containers/issues/473) — design tracker
- [#476](https://github.com/joshjhall/containers/issues/476) /
  [#479](https://github.com/joshjhall/containers/pull/479) — producer side (B)
- [#478](https://github.com/joshjhall/containers/issues/478) — workflow scheduling (D)
- [base-images/README.md](../../base-images/README.md) — how the base images this consumes are built and signed
- [docs/operations/ci-tiers.md](ci-tiers.md) — the broader CI cadence story; evidence runs are dispatch-only today
- [containers-db#14](https://github.com/joshjhall/containers-db/issues/14) — schema extension that enabled this work
