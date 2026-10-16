#!/usr/bin/env bash
# Unit tests for the branch-protection required-context set (issue #904).
#
# Background: `main` requires the status checks listed in
# `.github/required-checks.txt` before a PR can merge. That protection exists to
# close the #854 window, where a PR showing ZERO checks — because GitHub's
# `pull_request` event delivery lagged by 13m46s against a 3–4s baseline — could
# be merged on the absence of evidence.
#
# This test guards the MIRROR-IMAGE failure. A required context that never
# reports blocks `main` indefinitely: nothing can merge, and the cause (a
# renamed job, a narrowed trigger, a new `paths:` filter) is invisible because
# the workflow file still looks perfectly healthy on its own terms.
#
# The distinction that makes this subtle:
#
#   - A job that RUNS and concludes `SKIPPED` DOES satisfy a required context.
#     That is the healthy steady state here — `test-pr.yml` gates per-feature
#     builds behind change detection, so most checks legitimately sit in the
#     skipping bucket.
#   - A job that is NEVER SCHEDULED (its whole workflow was filtered out)
#     reports nothing at all, and blocks forever.
#
# So a required context must belong to a job whose workflow is triggered on
# EVERY pull request to `main`, unconditionally. Each test below covers one
# distinct way that stops being true.
#
# Two later additions extend the same never-reports/false-reports theme past
# the manifest itself:
#
#   - #910: a `check-name:` literal is a third copy of a job name that nothing
#     kept in sync. Its drift symptom is an indefinite WAIT, not an error.
#   - #909: `PR Tier` reporting is necessary but not sufficient — it must also
#     report FAILURE when the tier certified nothing. Those tests (and the
#     #1099 label mirror) live in tests/unit/required-checks-pr-tier.sh (#1271).
#
# Scope: this parses workflow YAML only — it never calls the GitHub API, so it
# runs offline and under SKIP_NETWORK_TESTS=1. It therefore verifies the
# manifest against the workflows in this checkout, NOT against the live branch
# protection setting. Drift between the manifest and the live setting is caught
# by reading the endpoint back (see docs/troubleshooting/ci-cd-issues.md).
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Branch protection required checks"

WORKFLOWS_DIR="$PROJECT_ROOT/.github/workflows"
MANIFEST="$PROJECT_ROOT/.github/required-checks.txt"

# The branch the protection applies to. A required context must report on every
# PR targeting this branch.
PROTECTED_BRANCH="main"

# Read the manifest: one context name per line, `#` comments and blanks
# stripped. Names may contain spaces ("Run Tests"), so callers MUST read this
# line-by-line and never word-split it.
read_manifest() {
    [ -f "$MANIFEST" ] || return 0
    /usr/bin/sed -E 's/[[:space:]]*#.*$//' "$MANIFEST" |
        /usr/bin/grep -vE '^[[:space:]]*$' |
        /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# Every workflow file, NUL-free one per line (no spaces in these filenames).
# Takes an optional directory so the resolver can be aimed at a fixture dir
# (#919) — the real .github/workflows/ must never hold a malformed file.
workflow_files() {
    local dir="${1:-$WORKFLOWS_DIR}"
    /usr/bin/find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | /usr/bin/sort
}

# require_yq + run_yq (fail-loud yq wrapper, #768/#919), shared with
# required-checks-pr-tier.sh.
# shellcheck source=tests/framework/helpers/required-checks.sh
source "$SCRIPT_DIR/../framework/helpers/required-checks.sh"

# Job-name lookup, built with ONE yq pass per workflow file for the whole suite
# (#919). The previous shape ran one yq per (literal × file) — a nested yq
# inside a process substitution whose body ran yq again — which is the shape the
# flake was traced to. Building the map once removes that nesting entirely and
# is strictly less work.
#
# Populated lazily on first use and reused across tests: `run_test` calls
# `setup()` before each test (fresh TEST_TEMP_DIR), so a file-backed cache would
# be rebuilt per test, while this in-process array survives. Note the loop body
# below runs in the CURRENT shell — only the process substitution is a subshell
# — so these writes do propagate.
declare -A JOB_NAME_FILES=()
JOB_NAME_MAP_BUILT=""
JOB_NAME_MAP_DIR=""

# Discard the cache so a later build re-reads its source directory.
reset_job_name_map() {
    JOB_NAME_FILES=()
    JOB_NAME_MAP_BUILT=""
    JOB_NAME_MAP_DIR=""
}

# Build the map for $1 (default: the real WORKFLOWS_DIR). Rebuilds when the
# requested dir differs from the cached one — that is the whole invalidation
# story, since workflow files do not change mid-run.
#
# Returns non-zero (loudly) if yq fails on ANY workflow file, and caches
# NOTHING in that case: a half-built map would silently under-report matches,
# which is the same false verdict this change exists to prevent. Leaving the
# cache empty also means each dependent test re-attempts and independently
# reddens, naming the broken file, rather than one test failing and the rest
# passing on a stale map.
build_job_name_map() {
    local dir="${1:-$WORKFLOWS_DIR}"
    # A missing or unreadable dir makes `find` print to its own stderr and emit
    # nothing, which the `while read` below cannot distinguish from "no
    # workflows here" — the same swallow this whole change exists to remove,
    # one layer up from yq. Fail loud instead.
    if [ ! -d "$dir" ]; then
        /usr/bin/echo "  workflow directory does not exist: $dir" >&2
        return 1
    fi
    if [ -n "$JOB_NAME_MAP_BUILT" ] && [ "$JOB_NAME_MAP_DIR" = "$dir" ]; then
        return 0
    fi
    JOB_NAME_FILES=()
    JOB_NAME_MAP_BUILT=""
    JOB_NAME_MAP_DIR=""

    local file names name
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # `(.jobs // {})` tolerates a workflow with a present-but-null `jobs:`
        # key, which `.jobs[]` alone treats as a hard error — a spurious
        # failure now that failures are fatal. `// ""` keeps jobs with no
        # explicit `name:` from becoming the string `null` and matching it.
        names=$(run_yq '(.jobs // {}) | .[] | (.name // "") ' "$file") || return 1
        [ -n "$names" ] || continue

        # One entry per FILE per name, never per job: a file with two
        # identically named jobs must still yield a single line, matching the
        # previous `grep -qxF` + single `printf` behavior. Reset per file.
        local -A seen_in_file=()
        while IFS= read -r name; do
            # Skip nameless jobs rather than indexing them under "": the old
            # `grep -qxF -- "$wanted"` could never match a blank line for a
            # non-empty query, so skipping preserves behavior exactly.
            [ -n "$name" ] || continue
            [ -z "${seen_in_file[$name]:-}" ] || continue
            seen_in_file[$name]=1
            if [ -z "${JOB_NAME_FILES[$name]:-}" ]; then
                JOB_NAME_FILES[$name]="$file"
            else
                JOB_NAME_FILES[$name]="${JOB_NAME_FILES[$name]}"$'\n'"$file"
            fi
        done <<<"$names"
    done < <(workflow_files "$dir")

    JOB_NAME_MAP_BUILT=1
    JOB_NAME_MAP_DIR="$dir"
}

# Print `<workflow-file>` for every job in any workflow whose job `name:` equals
# $1 exactly. Emits nothing when unmatched; multiple lines when ambiguous.
# Returns non-zero if the underlying yq pass failed — callers MUST check.
workflows_defining_job_name() {
    local wanted="$1"
    # Build against whatever dir is already cached (the real WORKFLOWS_DIR on
    # the first call). Passing no argument would re-target the default and
    # silently rebuild over a fixture map a test had just built.
    build_job_name_map "${JOB_NAME_MAP_DIR:-$WORKFLOWS_DIR}" || return 1
    # An empty subscript is a hard error under `set -u`, and no job is indexed
    # under "" anyway — so an empty query is always an empty answer.
    [ -n "$wanted" ] || return 0
    # `${...:-}` matters too: a bare missing-key lookup is fatal under `set -u`.
    [ -n "${JOB_NAME_FILES[$wanted]:-}" ] || return 0
    /usr/bin/printf '%s\n' "${JOB_NAME_FILES[$wanted]}"
}

test_manifest_exists_and_is_populated() {
    assert_true [ -f "$MANIFEST" ] ".github/required-checks.txt must exist"

    local count
    count=$(read_manifest | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    if [ "${count:-0}" -gt 0 ]; then
        assert_true true "manifest lists $count required context(s)"
    else
        assert_true false "manifest lists no required contexts — branch protection would gate on nothing"
    fi
}

# A context name is matched by GitHub against the job's rendered name. If the
# job is renamed or deleted, the context never reports and `main` locks up.
test_every_context_matches_exactly_one_job() {
    require_yq || return 0

    local violations=0 ctx matches count
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        matches=$(workflows_defining_job_name "$ctx") || {
            assert_true false "yq failed while resolving job names — cannot verify '$ctx' (see above)"
            return 0
        }
        count=$(/usr/bin/printf '%s' "$matches" | /usr/bin/grep -c . || true)
        if [ "$count" -eq 0 ]; then
            /usr/bin/echo "  no job named '$ctx' in any workflow — this context would never report"
            violations=$((violations + 1))
        elif [ "$count" -gt 1 ]; then
            /usr/bin/echo "  job name '$ctx' is ambiguous across workflows:"
            /usr/bin/printf '%s\n' "$matches" | /usr/bin/sed 's/^/    /'
            violations=$((violations + 1))
        fi
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "every required context maps to exactly one job"
    else
        assert_true false "$violations required context(s) do not map to exactly one job (see above)"
    fi
}

# The job must live in a workflow triggered on pull_request against the
# protected branch. A trigger narrowed to other branches means no report.
test_context_workflows_trigger_on_pull_request_to_protected_branch() {
    require_yq || return 0

    local violations=0 ctx file matches branches has_pr
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        matches=$(workflows_defining_job_name "$ctx") || {
            assert_true false "yq failed while resolving job names — cannot verify '$ctx' (see above)"
            return 0
        }
        file=$(/usr/bin/printf '%s\n' "$matches" | /usr/bin/head -1)
        [ -n "$file" ] || continue # unmatched names are the previous test's job

        # `on` is parsed by yq as the boolean key `true` in YAML 1.1, so query
        # both spellings rather than trusting either alone.
        has_pr=$(run_yq '((.on // .["on"]) // {}) | has("pull_request")' "$file") || {
            assert_true false "yq failed reading the trigger for '$ctx' (see above)"
            return 0
        }
        if ! /usr/bin/grep -qx 'true' <<<"$has_pr"; then
            /usr/bin/echo "  '$ctx' ($(/usr/bin/basename "$file")): workflow has no pull_request trigger"
            violations=$((violations + 1))
            continue
        fi

        # An absent `branches:` means all branches — that is fine. A present one
        # must include the protected branch.
        branches=$(run_yq '((.on // .["on"]).pull_request.branches // ["*ALL*"]) | .[]' "$file") || {
            assert_true false "yq failed reading trigger branches for '$ctx' (see above)"
            return 0
        }
        if ! /usr/bin/grep -qxF -- '*ALL*' <<<"$branches"; then
            if ! /usr/bin/grep -qxF -- "$PROTECTED_BRANCH" <<<"$branches"; then
                /usr/bin/echo "  '$ctx' ($(/usr/bin/basename "$file")): pull_request trigger excludes '$PROTECTED_BRANCH'"
                violations=$((violations + 1))
            fi
        fi
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "every required context's workflow triggers on PRs to $PROTECTED_BRANCH"
    else
        assert_true false "$violations required context(s) not triggered on PRs to $PROTECTED_BRANCH (see above)"
    fi
}

# THE trap. A `paths:`/`paths-ignore:` filter on the pull_request trigger means
# the whole workflow is not scheduled for PRs that touch nothing matching — the
# context reports NOTHING, and `main` becomes unmergeable for those PRs. This
# is distinct from a job that runs and skips, which satisfies the context fine.
test_context_workflows_have_no_pull_request_path_filters() {
    require_yq || return 0

    local violations=0 ctx file matches filter has_filter
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        matches=$(workflows_defining_job_name "$ctx") || {
            assert_true false "yq failed while resolving job names — cannot verify '$ctx' (see above)"
            return 0
        }
        file=$(/usr/bin/printf '%s\n' "$matches" | /usr/bin/head -1)
        [ -n "$file" ] || continue

        for filter in paths paths-ignore; do
            # THE false-pass site (#919): when this yq failed, the `grep -qx
            # true` below simply found nothing, no violation was recorded, and
            # the test passed having verified NOTHING.
            has_filter=$(run_yq "((.on // .[\"on\"]).pull_request // {}) | has(\"$filter\")" "$file") || {
                assert_true false "yq failed reading '$filter' for '$ctx' (see above)"
                return 0
            }
            if /usr/bin/grep -qx 'true' <<<"$has_filter"; then
                /usr/bin/echo "  '$ctx' ($(/usr/bin/basename "$file")): pull_request has a '$filter' filter — the workflow can be skipped entirely, so this context would never report and would block $PROTECTED_BRANCH"
                violations=$((violations + 1))
            fi
        done
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "no required context sits behind a pull_request path filter"
    else
        assert_true false "$violations required context(s) behind a path filter (see above)"
    fi
}

# A matrix-templated name (`Rust Tests (stibbons) — ${{ matrix.os }}`) renders
# to a different string per cell, so the literal is never a reportable context.
# Requiring one would block `main` forever while every cell passes.
test_context_names_are_not_templated() {
    local violations=0 ctx
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        if /usr/bin/grep -qF '${{' <<<"$ctx"; then
            /usr/bin/echo "  '$ctx' contains a \${{ }} expression — not a stable context name"
            violations=$((violations + 1))
        fi
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "no required context name contains a template expression"
    else
        assert_true false "$violations required context name(s) are templated (see above)"
    fi
}

# A `check-name:` literal (wait-on-check-action) is a THIRD copy of a job name,
# alongside the job's own `name:` and the manifest. The tests above keep the
# manifest and the jobs in sync but never read these literals, so this copy
# could drift silently (#910).
#
# The drift is not a loud error: wait-on-check-action polls for its check-name
# until the job timeout, so a name that never appears is an indefinite WAIT.
# Renaming ci.yml's `test` job and updating the manifest (which the tests above
# would force) leaves auto-merge.yml waiting on a string nothing reports, and
# version-update PRs simply stop auto-merging with no failure anywhere.
#
# Asserting against real job names — rather than against the manifest — catches
# exactly that rename without coupling every future wait-on-check to the
# branch-protection required list, which is a separate decision.
test_check_name_literals_match_a_real_job() {
    require_yq || return 0

    local violations=0 checked=0 file literal matches count literals
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # Recursive walk: `check-name:` sits inside a step's `with:` map at no
        # fixed depth, so match any map carrying the key rather than a path.
        #
        # Captured into a variable rather than piped from a process
        # substitution (#919): `done < <(yq ...)` makes yq's exit status
        # structurally UNOBSERVABLE, so the old `|| true` there was decoration
        # — a crashed yq silently checked zero literals and the test passed.
        literals=$(run_yq '[.. | select(type == "!!map" and has("check-name")) | .["check-name"]] | .[]' "$file") || {
            assert_true false "yq failed reading check-name literals from $(/usr/bin/basename "$file") (see above)"
            return 0
        }
        [ -n "$literals" ] || continue

        while IFS= read -r literal; do
            [ -n "$literal" ] || continue
            checked=$((checked + 1))

            # A templated literal renders per-run and can't be matched against a
            # static job name — flag it rather than silently passing it through.
            if /usr/bin/grep -qF '${{' <<<"$literal"; then
                /usr/bin/echo "  '$literal' ($(/usr/bin/basename "$file")): check-name contains a \${{ }} expression — cannot be verified against a job name"
                violations=$((violations + 1))
                continue
            fi

            matches=$(workflows_defining_job_name "$literal") || {
                assert_true false "yq failed while resolving job names — cannot verify '$literal' (see above)"
                return 0
            }
            count=$(/usr/bin/printf '%s' "$matches" | /usr/bin/grep -c . || true)
            if [ "$count" -eq 0 ]; then
                /usr/bin/echo "  '$literal' ($(/usr/bin/basename "$file")): no job with this name exists — wait-on-check-action would poll until timeout (a silent stall, not an error)"
                violations=$((violations + 1))
            elif [ "$count" -gt 1 ]; then
                /usr/bin/echo "  '$literal' ($(/usr/bin/basename "$file")): ambiguous across workflows:"
                /usr/bin/printf '%s\n' "$matches" | /usr/bin/sed 's/^/    /'
                violations=$((violations + 1))
            fi
        done <<<"$literals"
    done < <(workflow_files)

    if [ "$violations" -eq 0 ]; then
        assert_true true "all $checked check-name literal(s) resolve to exactly one job"
    else
        assert_true false "$violations check-name literal(s) do not map to exactly one job (see above)"
    fi
}

# --- the resolver's own failure modes (#919) --------------------------------
#
# Everything above trusts the resolver. These two tests are what make that
# trust earned, by running it against fixtures the real .github/workflows/
# cannot provide: a file yq cannot parse, and duplicate job names.
#
# Fixtures are WRITTEN AT RUNTIME under $TEST_TEMP_DIR rather than committed.
# A malformed workflow committed under .github/workflows/ would break actions
# tooling repo-wide, and a committed fixture elsewhere is the standing
# scaffolding that turns each round of guards into the next round's undriven
# branches. Never tests/results/ — that path is an incoherent FUSE mount whose
# write-then-read loses ~0.75%/op (#821).

# Write $2 into $1, creating parent dirs. Keeps the fixture bodies readable.
write_fixture() {
    local path="$1" body="$2"
    /usr/bin/mkdir -p "$(/usr/bin/dirname "$path")"
    /usr/bin/printf '%s' "$body" >"$path"
}

# The crux of #919: a yq failure and a legitimate empty answer must be
# DIFFERENT outcomes. Both halves are load-bearing and neither alone is enough
# — assertion 1 alone is satisfied by a resolver that fails on everything, and
# assertions 2-4 alone are satisfied by the old swallow-everything resolver.
#
# To prove assertion 1 bites: revert build_job_name_map's `|| return 1` to
# `|| true`. Assertion 1 must go red, and only assertion 1.
test_yq_failure_is_distinguishable_from_empty() {
    require_yq || return 0

    local bad_dir="$TEST_TEMP_DIR/wf-bad" good_dir="$TEST_TEMP_DIR/wf-good"
    local violations=0 out rc

    # Tabs are illegal as YAML indentation unconditionally, so this fails on
    # every yq/libyaml build — unlike an unterminated quote, which is more
    # version-sensitive.
    write_fixture "$bad_dir/broken.yml" 'jobs:
	a:
		name: x
'
    # Valid YAML with NO `jobs:` key at all — the legitimate empty answer that
    # must stay distinct from the failure above.
    write_fixture "$good_dir/nojobs.yml" 'name: x
on: push
'
    write_fixture "$good_dir/a.yml" 'on:
  pull_request:
jobs:
  s:
    name: Sentinel Job
'

    # 1. A file yq cannot parse FAILS, and says so.
    rc=0
    out=$(build_job_name_map "$bad_dir" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        /usr/bin/echo "  a malformed workflow did NOT fail the resolver — a yq error is rendering as 'no such job'"
        violations=$((violations + 1))
    elif ! /usr/bin/grep -qF 'broken.yml' <<<"$out"; then
        /usr/bin/echo "  resolver failed but did not name the offending file: $out"
        violations=$((violations + 1))
    fi

    # 2. Valid YAML with no jobs at all SUCCEEDS (empty is a real answer).
    reset_job_name_map
    if ! build_job_name_map "$good_dir" >/dev/null 2>&1; then
        /usr/bin/echo "  a valid workflow set was rejected — the guard fails everything, not just parse errors"
        violations=$((violations + 1))
    fi

    # 3. A name that genuinely is not there returns empty, and returns 0.
    rc=0
    out=$(workflows_defining_job_name 'No Such Job') || rc=$?
    if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
        /usr/bin/echo "  an absent job name should be an empty success, got rc=$rc out='$out'"
        violations=$((violations + 1))
    fi

    # 4. A present one resolves to its file.
    out=$(workflows_defining_job_name 'Sentinel Job') || out=""
    if ! /usr/bin/grep -qF 'a.yml' <<<"$out"; then
        /usr/bin/echo "  a present job name did not resolve to its file, got '$out'"
        violations=$((violations + 1))
    fi

    # 5. A missing directory fails loud too — `find` on a nonexistent path
    #    emits nothing, which would otherwise read as "no workflows here".
    reset_job_name_map
    rc=0
    out=$(build_job_name_map "$TEST_TEMP_DIR/wf-does-not-exist" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        /usr/bin/echo "  a nonexistent workflow dir returned success — an empty build would read as 'no such job'"
        violations=$((violations + 1))
    elif ! /usr/bin/grep -qF 'wf-does-not-exist' <<<"$out"; then
        /usr/bin/echo "  missing-dir failure did not name the directory: $out"
        violations=$((violations + 1))
    fi

    # 6. The path-filter false-pass, pinned directly: a parse failure and a
    #    legitimate `false` must not look alike.
    rc=0
    run_yq '((.on // .["on"]).pull_request // {}) | has("paths")' "$bad_dir/broken.yml" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        /usr/bin/echo "  run_yq returned success on an unparsable file — the path-filter check would pass having verified nothing"
        violations=$((violations + 1))
    fi
    out=$(run_yq '((.on // .["on"]).pull_request // {}) | has("paths")' "$good_dir/a.yml" 2>/dev/null) || out="FAILED"
    if [ "$out" != "false" ]; then
        /usr/bin/echo "  a legitimate 'no paths filter' answer should be 'false', got '$out'"
        violations=$((violations + 1))
    fi

    reset_job_name_map
    if [ "$violations" -eq 0 ]; then
        assert_true true "a yq failure is distinguishable from a legitimate empty result"
    else
        assert_true false "$violations resolver failure-mode(s) wrong (see above)"
    fi
}

# The index rewrite (#919) must preserve the old `grep -qxF` + one-printf-per-
# file semantics exactly, because the ambiguity verdict above is computed by
# COUNTING LINES. An index emitting one line per job rather than per file would
# report a single file's twin jobs as cross-workflow ambiguity — and the real
# workflows happen not to exercise that, so only a fixture catches it.
test_job_name_index_semantics() {
    require_yq || return 0

    local dir="$TEST_TEMP_DIR/wf-dup" violations=0 out count

    # Two jobs, same rendered name, SAME file.
    # Job `d` has NO `name:` and is deliberately NOT last. yq renders it as an
    # empty line, and command substitution strips TRAILING newlines — so a
    # nameless job in final position is swallowed before the loop ever sees it,
    # making the builder's `[ -n "$name" ] || continue` guard unreachable and
    # any assertion about it non-discriminating. Interior position is what puts
    # an empty `$name` through the loop body for real.
    write_fixture "$dir/twin.yml" 'jobs:
  a:
    name: Twin
  b:
    name: Twin
  d:
    runs-on: ubuntu-latest
  c:
    name: Spaced ${{ matrix.os }} Name
'
    # A third job with that name in a DIFFERENT file.
    write_fixture "$dir/twin2.yml" 'jobs:
  e:
    name: Twin
'
    reset_job_name_map
    if ! build_job_name_map "$dir" >/dev/null 2>&1; then
        assert_true false "could not build the job-name index from fixtures"
        reset_job_name_map
        return 0
    fi

    # Two FILES define Twin (three jobs) — the count must be 2, not 3.
    out=$(workflows_defining_job_name 'Twin') || out=""
    count=$(/usr/bin/printf '%s' "$out" | /usr/bin/grep -c . || true)
    if [ "$count" -ne 2 ]; then
        /usr/bin/echo "  'Twin' spans 2 files (3 jobs) — expected 2 lines, got $count"
        violations=$((violations + 1))
    fi

    # Names with spaces and ${{ }} survive as exact keys.
    out=$(workflows_defining_job_name 'Spaced ${{ matrix.os }} Name') || out=""
    if ! /usr/bin/grep -qF 'twin.yml' <<<"$out"; then
        /usr/bin/echo "  a job name containing spaces and \${{ }} did not round-trip as a key"
        violations=$((violations + 1))
    fi

    # A job with no `name:` (fixture job `d`) must not be indexed AT ALL.
    #
    # Assert on the key COUNT rather than by querying a key — two spellings
    # that look right are both non-discriminating. `workflows_defining_job_name
    # ''` short-circuits on an empty argument before it ever consults the
    # array, so it answers empty whether or not the builder's
    # `[ -n "$name" ] || continue` guard exists. And bash rejects an empty
    # associative-array subscript outright (`bad array subscript`) on read as
    # well as write, so `${JOB_NAME_FILES[""]}` cannot even be spelled.
    #
    # What deleting the guard actually does is let an empty `$name` reach the
    # assignment, where that same subscript error aborts the builder — and with
    # it the whole suite. The fixtures hold exactly two distinct NAMED jobs
    # across both files (`Twin`, three jobs collapsing to one key, and
    # `Spaced ${{ … }} Name`), so this count is what pins the behavior.
    count=${#JOB_NAME_FILES[@]}
    if [ "$count" -ne 2 ]; then
        /usr/bin/echo "  expected exactly 2 indexed job names (Twin, Spaced…Name), got $count: ${!JOB_NAME_FILES[*]}"
        violations=$((violations + 1))
    fi

    reset_job_name_map
    if [ "$violations" -eq 0 ]; then
        assert_true true "the job-name index preserves per-file, exact-match semantics"
    else
        assert_true false "$violations job-name index semantic(s) wrong (see above)"
    fi
}

run_test test_manifest_exists_and_is_populated "manifest exists and lists contexts"
run_test test_every_context_matches_exactly_one_job "each context maps to exactly one job"
run_test test_context_workflows_trigger_on_pull_request_to_protected_branch "each context's workflow triggers on PRs to $PROTECTED_BRANCH"
run_test test_context_workflows_have_no_pull_request_path_filters "no context sits behind a pull_request path filter"
run_test test_context_names_are_not_templated "context names are not templated"
run_test test_check_name_literals_match_a_real_job "each check-name literal maps to exactly one job"
run_test test_yq_failure_is_distinguishable_from_empty "a yq failure is distinguishable from an empty result"
run_test test_job_name_index_semantics "the job-name index preserves per-file, exact-match semantics"

generate_report
