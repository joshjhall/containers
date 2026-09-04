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
- Making it **binding** rather than advisory needs branch protection, below.

**Recommended follow-up — branch protection.** The script is advisory. `main`
currently has no protection (`gh api repos/OWNER/REPO/branches/main/protection`
→ 404), so nothing at the platform level stops a zero-check merge. Required
status checks anchored on the stable rollup job names — `Run Tests`
(`ci.yml`) and `PR Tier` (`test-pr.yml`, which
[`ci-tiers.md`](../operations/ci-tiers.md) notes exists precisely "for branch
protection") — would make `gh pr merge --auto` genuinely safe, since GitHub
holds the merge until those contexts report. The trade-off worth weighing
first: a renamed workflow job then silently blocks every PR until the
required-contexts list is updated.

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
