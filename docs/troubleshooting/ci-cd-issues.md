# CI/CD Issues

This section covers issues specific to continuous integration and deployment
pipelines, including test failures, timeouts, and security scanning.

## Integration tests failing

**Symptom**: Integration tests fail with build errors or tool verification
failures.

**Common Causes**:

1. **apt-key deprecation** (see
   [Debian Version Compatibility](debian-compatibility.md))
1. **Network timeouts** during tool downloads
1. **Version mismatches** between pinned versions and available versions

**Solution**:

```bash
# Run integration tests locally to debug
./tests/run_integration_tests.sh

# Run specific test
./tests/run_integration_tests.sh cloud_ops

# Check test framework logs
cat tests/results/*.log

# Verify all tools can be installed
docker build --build-arg INCLUDE_KUBERNETES=true \
  --build-arg INCLUDE_TERRAFORM=true \
  --build-arg INCLUDE_AWS=true \
  -t test:debug .
```

**Available Integration Tests**:

- `minimal` - Base container with no features
- `python_dev` - Python + dev tools + databases + Docker
- `node_dev` - Node.js + dev tools + databases + Docker
- `cloud_ops` - Kubernetes + Terraform + AWS + GCloud
- `polyglot` - Python + Node.js multi-language
- `rust_golang` - Rust + Go systems programming

## GitHub Actions: Build timeout

**Symptom**: Build exceeds 6 hour timeout.

**Solution**:

```yaml
# Use layer caching
- uses: docker/build-push-action@v6
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max

# Build only necessary variants
matrix:
  variant: [minimal, python-dev]  # Reduced from 5 to 2
```

## GitHub Actions: PR shows zero checks

**Symptom**: A PR reports no checks at all. `gh pr checks` prints the
reassuring `no checks reported on the 'feature/x' branch`, and
`gh api repos/OWNER/REPO/commits/SHA/check-runs` returns `total_count: 0`.

**This usually means the events are late, not lost.** Check-runs on a commit is
the wrong probe: it cannot distinguish "the workflow never triggered" from "the
`pull_request` event has not been delivered yet". Query the workflow runs
instead and compare their `created_at` against the PR's `createdAt`:

```bash
# Did pull_request actually fire for this branch?
gh api "repos/OWNER/REPO/actions/runs?branch=feature%2Fissue-N" \
  --jq '.workflow_runs[] | "\(.event)  \(.name)  \(.created_at)"'

gh pr view N --json createdAt --jq .createdAt
```

Investigation of #854 (PR #848) found the reported "trigger never fired" was
really a **13m46s delivery delay** — four `pull_request` runs existed all along.
PR #847, cited at the time as the healthy control, was **17m44s** late in the
same ~35-minute window. Normal arrival on this repo is **3–4 seconds**. Repo
Actions settings, `ci.yml` concurrency, and `pull_request` path filters were all
ruled out; the cause was a transient GitHub Actions event-delivery backlog.

**Why it matters**: zero checks is ambiguous between "has not started yet" and
"will never start", and every gate keyed on *no failures* resolves it the
dangerous way. A merge in that window is green-lit by the absence of evidence.

**Guard**: `bin/check-pr-checks.sh` treats zero checks past a grace period as
**not passing** rather than not failing:

```bash
just check-pr-checks 896
# verdict=pass|fail|absent|pending   (exit 0|1|3|4; 0 means mergeable)
```

Two details it handles that a hand-rolled check will not:

- **`effective_checks = total - skipping`.** Most checks here legitimately sit
  in the skipping bucket (PR #896: 13 of 23), so a raw `count > 0` test would
  pass a PR on which nothing ran.
- **`statusCheckRollup` has no `bucket` field** — that belongs to
  `gh pr checks`. The rollup spells outcomes in UPPERCASE via `.status` /
  `.conclusion` (`CheckRun`) or `.state` (`StatusContext`). A lowercase match
  counts zero everywhere, which renders as a clean pass.
- **Unrecognized outcomes fail closed.** Only an explicit `SUCCESS` counts as
  passing; a null conclusion, an unfamiliar `__typename`, or a status GitHub
  adds later is treated as failing. Enumerating failure names instead would
  fail *open* — the unknown value would match no bucket and emerge as a pass.

Grace defaults to 300s (~75x the measured baseline, well inside the observed
incident); override with `PR_CHECKS_GRACE_SEC`.

**Scope — what this does and does not gate.** The script is **advisory**: it
reports a verdict, it does not block anything by itself. Know which merge paths
it covers:

- `.github/workflows/auto-merge.yml` is **already safe** — it waits on a
  *named* check (`Run Tests`) via `wait-on-check-action`, so an empty rollup
  makes it wait rather than proceed. Zero checks cannot green-light that path.
- The **model-driven ship flow** is the exposed one. Its CI poll terminates
  when no check is `pending`, which an empty list satisfies immediately. That
  logic lives outside this repo, so this script is the piece a reviewer or an
  automation wrapper can call — `just check-pr-checks <N>` before merging, and
  treat any non-zero exit as *do not merge*.
- What makes the gate **binding** rather than advisory is branch protection —
  below.

**Branch protection on `main` (#904).** Requiring status checks makes GitHub
itself hold a merge until real evidence reports — that is what closes the
zero-check window on the PR path. The script above stays useful either way,
because it explains *why* a PR is unmergeable (`absent` vs `pending` vs `fail`),
which a greyed-out merge button does not.

> **Status: decided, not yet applied.** The settings below are agreed and
> guarded in-repo, but the live `main` branch is still unprotected — applying
> them needs a token with the repo **Administration: Read and write**
> permission, which the fine-grained PAT in this environment does not carry
> (`gh api -X PUT …/protection` → `403 Resource not accessible by personal
> access token`; the read endpoint still returns `404 Branch not protected`).
> Apply with the command below from a session whose token has that permission,
> or via **Settings → Branches → Add rule** in the web UI, then flip this note.

Settings to apply:

| Setting | Value |
| --- | --- |
| Required contexts | `Run Tests` (`ci.yml`), `PR Tier` (`test-pr.yml`) |
| `strict` (branch must be up to date) | `false` |
| `enforce_admins` | `false` |
| Required reviews | none |

The context list lives in [`.github/required-checks.txt`](../../.github/required-checks.txt)
— the manifest is the only in-repo trace of a setting that otherwise lives
invisibly in repo settings. Apply it, then read the live values back:

```bash
gh api -X PUT repos/OWNER/REPO/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {"strict": false, "contexts": ["Run Tests", "PR Tier"]},
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON

gh api repos/OWNER/REPO/branches/main/protection \
  --jq '{contexts: .required_status_checks.contexts,
         strict: .required_status_checks.strict,
         admins: .enforce_admins.enabled}'
```

Why the two permissive settings are deliberate, not oversights:

- **`enforce_admins: false`** — `auto-patch.yml`'s `post-merge` job pushes
  **directly** to `main` (`git push origin HEAD:main` for the compatibility
  matrix) and pushes a `v*` tag. Admin enforcement would break the release bot.
  The cost is that an admin can still direct-push; the goal here is the
  zero-check *merge* window on the PR path.
- **No required reviews** — a required approval would block solo PRs from
  self-merging and would deadlock the auto-patch bot's `gh pr merge --auto`,
  since no second reviewer exists.
- **`strict: false`** — `strict: true` forces every PR to rebase whenever `main`
  moves, which with a bot pushing to `main` on a schedule means near-constant
  rebasing for no added safety.

**The failure mode this creates, and its guard.** A required context that never
reports blocks `main` **indefinitely** — the mirror image of #854: instead of
merging when it shouldn't, nothing can merge at all. Two cases behave
differently, and the difference is easy to get backwards:

- A job that **runs** and concludes `SKIPPED` **does** satisfy a required
  context. That is the healthy steady state here — most checks on a typical PR
  legitimately sit in the skipping bucket.
- A job that is **never scheduled** (its whole workflow filtered out by a
  `paths:` filter, a narrowed `branches:` list, or a rename) reports nothing,
  and blocks forever.

`tests/unit/required-checks.sh` guards this offline: every name in the manifest
must map to exactly one job, in a workflow triggered on every PR to `main`, with
no `paths:`/`paths-ignore:` filter on that trigger and no `${{ }}` in the job
name. **Add a context to the manifest only if it reports on every PR regardless
of what changed** — and update the live setting too; the manifest does not apply
itself.

**Recovery — `main` is stuck and nothing can merge.** If a required context
stops reporting, an admin can lift protection, fix the workflow (or the
manifest), and re-apply:

```bash
gh api -X DELETE repos/OWNER/REPO/branches/main/protection
```

## GitHub Actions: Rate limit exceeded

**Symptom**: API calls to GitHub fail with 403.

**Solution**:

```yaml
# Ensure GITHUB_TOKEN is used
env:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

# Add retry logic
- name: Check versions
  run: |
    for i in {1..3}; do
      ./bin/check-versions.sh && break || sleep 30
    done
```

## Security scanning fails

**Symptom**: Trivy or Gitleaks fail the build.

**Solution**:

```yaml
# For Trivy, allow high severity
- uses: aquasecurity/trivy-action@master
  with:
    severity: "CRITICAL" # Only fail on critical

# For Gitleaks, use baseline
- uses: gitleaks/gitleaks-action@v2
  with:
    args: --baseline-path=.gitleaks-baseline.json
```

## Image pull fails in CI

**Symptom**: Cannot pull image for scanning.

**Solution**:

```yaml
# Ensure login happens first
- name: Log in to registry
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

# Check image exists
- run: docker images
```
