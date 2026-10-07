#!/usr/bin/env bash
# Unit tests for the pre-push network-test skip wiring (issue #615).
#
# Background: the lefthook pre-push hook runs tests/run_changed_tests.sh. When a
# foundational file (tests/framework.sh, tests/framework/*, Dockerfile) changes,
# that runner maps to ALL and execs the whole unit suite — which includes
# tests/unit/bin/check-versions.sh, a test that invokes the real
# bin/check-versions.sh and curls api.github.com once per tracked tool. Under
# concurrent golems those calls serialize and a git push stalls for minutes.
#
# The fix: run_changed_tests.sh exports SKIP_NETWORK_TESTS=1, and live-network
# tests skip via the network_tests_disabled helper. CI is unaffected because it
# invokes run_unit_tests.sh directly (the flag stays unset there). These tests
# lock that wiring in so a future edit can't silently restore the live calls to
# the push gate.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Pre-push network-test skip wiring (#615)"

FRAMEWORK="$PROJECT_ROOT/tests/framework.sh"
RUNNER="$PROJECT_ROOT/tests/run_changed_tests.sh"
CHECK_VERSIONS_TEST="$PROJECT_ROOT/tests/unit/bin/check-versions.sh"
VERSION_RESOLUTION_TEST="$PROJECT_ROOT/tests/unit/base/version-resolution.sh"

# The runner is what the pre-push hook invokes; it must set the flag so the ALL
# path and per-file invocations both skip network tests.
test_runner_exports_flag() {
    if command grep -qE '^[[:space:]]*export SKIP_NETWORK_TESTS=' "$RUNNER"; then
        pass_test "run_changed_tests.sh exports SKIP_NETWORK_TESTS"
    else
        fail_test "run_changed_tests.sh must export SKIP_NETWORK_TESTS (pre-push gate)"
    fi
}

# The helper is the single consultation point; it must be defined and exported
# so subprocess test files inherit it.
test_framework_defines_helper() {
    assert_contains "$(/usr/bin/cat "$FRAMEWORK")" "network_tests_disabled()" \
        "framework.sh defines network_tests_disabled"
}

test_framework_exports_helper() {
    if command grep -qE '^export -f .*network_tests_disabled' "$FRAMEWORK"; then
        pass_test "framework.sh exports network_tests_disabled"
    else
        fail_test "framework.sh must export -f network_tests_disabled (subprocess inheritance)"
    fi
}

test_helper_keys_on_env() {
    assert_contains "$(/usr/bin/cat "$FRAMEWORK")" 'SKIP_NETWORK_TESTS:-' \
        "network_tests_disabled keys on the SKIP_NETWORK_TESTS env var"
}

# The named culprit: each live-script test must be guarded by name. Asserting on
# the specific function bodies (rather than a count threshold) means a newly
# added unguarded network test is caught, not masked by the existing guards.
test_check_versions_guards_live_tests() {
    local func
    for func in test_missing_env_file test_json_output_format test_json_output_valid; do
        # The guard must appear within ~6 lines of the function header.
        if command grep -A6 "^${func}()" "$CHECK_VERSIONS_TEST" |
            command grep -q "network_tests_disabled"; then
            pass_test "check-versions.sh guards $func with network_tests_disabled"
        else
            fail_test "check-versions.sh must guard $func with network_tests_disabled"
        fi
    done
}

# version-resolution.sh routes ~18 network tests through check_network; that
# helper must honor the flag too.
test_version_resolution_honors_flag() {
    assert_contains "$(/usr/bin/cat "$VERSION_RESOLUTION_TEST")" "network_tests_disabled" \
        "version-resolution.sh check_network honors the skip flag"
}

# Behavioral checks of the already-sourced helper. We toggle SKIP_NETWORK_TESTS
# in-process (save/restore) rather than spawning `bash -c "source ...; ..."` —
# inside `bash -c` BASH_SOURCE[0] is empty, so framework.sh's TESTS_DIR would
# resolve to the cwd and the helper would never load. One assertion per test so
# run_test's per-test PASS/FAIL accounting stays correct.
test_helper_enabled() {
    local saved="${SKIP_NETWORK_TESTS:-}"
    SKIP_NETWORK_TESTS=1
    if network_tests_disabled; then
        pass_test "network_tests_disabled true when SKIP_NETWORK_TESTS=1"
    else
        fail_test "network_tests_disabled should be true when SKIP_NETWORK_TESTS=1"
    fi
    SKIP_NETWORK_TESTS="$saved"
}

test_helper_dev_override() {
    local saved="${SKIP_NETWORK_TESTS:-}"
    SKIP_NETWORK_TESTS=0
    if network_tests_disabled; then
        fail_test "network_tests_disabled should be false when SKIP_NETWORK_TESTS=0"
    else
        pass_test "network_tests_disabled false when SKIP_NETWORK_TESTS=0"
    fi
    SKIP_NETWORK_TESTS="$saved"
}

# The unset case is the CI path (run_unit_tests.sh leaves the flag unset and
# must run the full network matrix). Guard against a regression that treats
# "unset" as "disabled".
test_helper_ci_path_unset() {
    local saved="${SKIP_NETWORK_TESTS:-}"
    unset SKIP_NETWORK_TESTS
    if network_tests_disabled; then
        fail_test "network_tests_disabled should be false when unset (CI path)"
    else
        pass_test "network_tests_disabled false when SKIP_NETWORK_TESTS unset (CI path)"
    fi
    [ -n "$saved" ] && export SKIP_NETWORK_TESTS="$saved"
    return 0
}

# ============================================================================
# Runtime-script test mapping (issue #832)
# ============================================================================
# The lib/runtime arm of map_to_test used to match on the bare basename, so
# lib/runtime/42-workspace-fs-health.sh resolved to
# tests/unit/runtime/42-workspace-fs-health.sh — a path that has never existed.
# The arm emitted nothing and the runner treated that as "no tests needed", so a
# changed runtime script ran no tests at push time with no error to notice.
# Splitting a suite into siblings (#832) made a second failure mode reachable:
# emitting only the first glob match would silently narrow coverage.
#
# These call map_to_test directly rather than grepping the runner's source, so
# they assert what it RESOLVES, not how it is spelled.

# Extract map_to_test from the runner into this shell. The function is
# self-contained (it reads only $TESTS_DIR/$PROJECT_ROOT and echoes paths), so
# it can be evaluated without executing the runner's push-time side effects.
#
# SECURITY: this `eval`s text read from $RUNNER. That is safe ONLY because
# $RUNNER is a fixed repo-local path ($PROJECT_ROOT/tests/run_changed_tests.sh)
# with no env or CLI override — it is the same trust boundary as sourcing the
# file. If $RUNNER ever becomes configurable, this becomes a code-injection
# path into the test process and must be replaced by sourcing a dedicated
# fragment instead of parsing one out.
_load_map_to_test() {
    local body
    body=$(/usr/bin/awk '/^map_to_test\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$RUNNER")
    [ -n "$body" ] || return 1
    eval "$body"
}

test_runtime_mapping_strips_order_prefix() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    out=$(map_to_test "lib/runtime/42-workspace-fs-health.sh")
    assert_contains "$out" "tests/unit/runtime/workspace-fs-health.sh" \
        "NN- prefixed runtime script must map to its unprefixed suite"
}

test_runtime_mapping_emits_all_siblings() {
    local out count
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    out=$(map_to_test "lib/runtime/42-workspace-fs-health.sh")

    # Pin every known sibling by NAME, not a loose count. A bare `count > 1`
    # would stay green if the glob silently dropped one of the six, which is
    # the same "coverage narrows and nobody notices" failure this arm exists to
    # prevent. Six suites cover this script today: the split pair (#832), the
    # pre-existing cron-entry suite, the worktree suite (#882), the xattr
    # ELOOP diagnostic suite (#980), and the PROJECT_ROOT scope suite (#917).
    assert_contains "$out" "workspace-fs-health.sh" \
        "the exact-match suite must be included"
    assert_contains "$out" "workspace-fs-health-submodules.sh" \
        "split sibling suite must be included, not just the first glob match"
    assert_contains "$out" "workspace-fs-health-cron-entry.sh" \
        "pre-existing cron-entry sibling must be included"
    assert_contains "$out" "workspace-fs-health-worktrees.sh" \
        "linked-worktree sibling suite must be included (#882)"
    assert_contains "$out" "workspace-fs-health-xattr.sh" \
        "xattr ELOOP diagnostic sibling suite must be included (#980)"
    assert_contains "$out" "workspace-fs-health-scope.sh" \
        "PROJECT_ROOT scope sibling suite must be included (#917)"

    # Every emitted path must be a real file — a stale glob would otherwise
    # feed a nonexistent path to the runner.
    count=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        count=$((count + 1))
        assert_file_exists "$path" "mapped test path must exist: $path"
    done <<<"$out"

    assert_equals "6" "$count" \
        "exactly the six known workspace-fs-health suites must be mapped"
}

test_runtime_mapping_keeps_prefixed_suites() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # The test files are INCONSISTENT about keeping the NN- prefix, so both
    # spellings must resolve. These two keep theirs; workspace-fs-health drops
    # it. A stripped-only lookup silently breaks these.
    out=$(map_to_test "lib/runtime/05-cleanup-init-env.sh")
    assert_contains "$out" "tests/unit/runtime/05-cleanup-init-env.sh" \
        "a runtime suite that KEEPS its NN- prefix must still be found"

    out=$(map_to_test "lib/runtime/60-setup-git.sh")
    assert_contains "$out" "tests/unit/runtime/60-setup-git.sh" \
        "60-setup-git.sh must map to its OWN suite, not the stripped-name one"
}

test_runtime_mapping_no_duplicate_paths() {
    local out uniq_count total_count
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # An unprefixed script makes the prefixed and stripped passes identical, so
    # without dedup every path would be emitted twice and run twice.
    out=$(map_to_test "lib/runtime/audit-logger.sh")
    total_count=$(command printf '%s\n' "$out" | command grep -c . || true)
    uniq_count=$(command printf '%s\n' "$out" | command grep . | command sort -u | command wc -l)

    assert_equals "$total_count" "$uniq_count" \
        "map_to_test must not emit the same test path twice"
}

test_runtime_mapping_unmatched_is_silent() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # A runtime script with no suite must emit nothing rather than a bogus path.
    out=$(map_to_test "lib/runtime/99-no-such-runtime-script.sh")
    assert_empty "$out" "an uncovered runtime script must map to no test path"
}

# The bin arm fans out to <stem>-*.sh siblings for the same reason the runtime
# arm does: check-versions.sh was split (#1024), and a changed
# bin/check-versions.sh must still run the moved checker-mock suite at push time.
test_bin_mapping_emits_all_siblings() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # The exact set, not a count: a count of 2 passes if a sibling is swapped
    # for some other existing suite or duplicated in place of one.
    out=$(map_to_test "bin/check-versions.sh" | command sort)
    assert_equals "$TESTS_DIR/unit/bin/check-versions-checkers.sh
$TESTS_DIR/unit/bin/check-versions.sh" "$out" \
        "exactly the exact-match suite and its split sibling must be mapped (#1024)"
}

# The runner's own collection loop, not just map_to_test. #832's sibling fanout
# was pinned only at the map_to_test level, while the loop that consumed it
# joined a multi-path result with `| xargs` into one non-file key that the -f
# filter then dropped — so a split suite ran NOTHING at push time, and no test
# noticed. Drive the loop with a changed bin script and a changed runtime
# script and require every emitted line to be one real suite.
_load_map_changed_files() {
    local body
    _load_map_to_test || return 1
    body=$(/usr/bin/awk '/^map_changed_files\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$RUNNER")
    [ -n "$body" ] || return 1
    eval "$body"
}

test_collection_keeps_each_sibling_suite() {
    local out
    if ! _load_map_changed_files; then
        fail_test "could not extract map_changed_files from $RUNNER"
        return 0
    fi

    # The exact sorted set, each on its own line: a joined line (the xargs bug),
    # a dropped sibling, a duplicate, or a substituted suite all change it.
    out=$(command printf '%s\n' bin/check-versions.sh \
        lib/runtime/42-workspace-fs-health.sh | map_changed_files | command sort)
    assert_equals "$TESTS_DIR/unit/bin/check-versions-checkers.sh
$TESTS_DIR/unit/bin/check-versions.sh
$TESTS_DIR/unit/runtime/workspace-fs-health-cron-entry.sh
$TESTS_DIR/unit/runtime/workspace-fs-health-scope.sh
$TESTS_DIR/unit/runtime/workspace-fs-health-submodules.sh
$TESTS_DIR/unit/runtime/workspace-fs-health-worktrees.sh
$TESTS_DIR/unit/runtime/workspace-fs-health-xattr.sh
$TESTS_DIR/unit/runtime/workspace-fs-health.sh" "$out" \
        "every sibling suite of both changed scripts, each once, must be collected"
}

# A bin script with no suite must collect nothing — neither a bogus exact path
# nor a stray glob match (an unmatched `<stem>-*.sh` glob stays literal, so the
# -f guard in the bin arm is what keeps it out).
test_bin_unmatched_collects_nothing() {
    local out
    if ! _load_map_changed_files; then
        fail_test "could not extract map_changed_files from $RUNNER"
        return 0
    fi

    out=$(map_to_test "bin/no-such-tool-1024.sh")
    assert_empty "$out" "an uncovered bin script must map to no test path"

    out=$(command printf '%s\n' bin/no-such-tool-1024.sh | map_changed_files)
    assert_empty "$out" "an uncovered bin script must collect no test path"
}

test_collection_stops_at_all() {
    local out
    if ! _load_map_changed_files; then
        fail_test "could not extract map_changed_files from $RUNNER"
        return 0
    fi

    # Foundational file FIRST, a mappable one after: collection must stop at
    # ALL. With ALL last, removing the early return would still leave ALL as
    # the final line and the test would prove nothing.
    out=$(command printf '%s\n' tests/framework.sh bin/check-versions.sh | map_changed_files)
    assert_equals "ALL" "$out" \
        "a foundational file must end the collection with ALL and nothing after"
}

# ============================================================================
# bin sibling ownership + nested paths, and the main-block collection (#1031)
# ============================================================================

# Build a throwaway tree: bin/check.sh and bin/check-versions.sh, with
# check.sh's own split suite (check-foo.sh, no bin/check-foo.sh) beside
# check-versions' two suites. Prints the root.
_make_bin_fixture() {
    local root
    root=$(/usr/bin/mktemp -d)
    /usr/bin/mkdir -p "$root/bin" "$root/tests/unit/bin"
    /usr/bin/touch "$root/bin/check.sh" "$root/bin/check-versions.sh" \
        "$root/tests/unit/bin/check.sh" \
        "$root/tests/unit/bin/check-foo.sh" \
        "$root/tests/unit/bin/check-versions.sh" \
        "$root/tests/unit/bin/check-versions-checkers.sh"
    command echo "$root"
}

# A stem that is a prefix of another bin script's stem must not collect that
# script's suites: check-versions.sh and check-versions-checkers.sh belong to
# bin/check-versions.sh, the longer matching stem.
test_bin_sibling_skips_longer_owned_suite() {
    local root out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi
    root=$(_make_bin_fixture)

    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/check.sh" | command sort)
    assert_equals "$root/tests/unit/bin/check-foo.sh
$root/tests/unit/bin/check.sh" "$out" \
        "bin/check.sh must keep its own split suite and skip check-versions*"

    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/check-versions.sh" | command sort)
    assert_equals "$root/tests/unit/bin/check-versions-checkers.sh
$root/tests/unit/bin/check-versions.sh" "$out" \
        "bin/check-versions.sh must still own both of its suites"

    /usr/bin/rm -rf "$root"
}

# Ownership must be decided by the LONGEST stem, checked at every `-` boundary,
# not just the first trim: with bin/check-versions-checkers.sh present, the
# check-versions-checkers-x.sh suite belongs to it, and the
# check-versions-checkers.sh suite becomes its exact match rather than a
# sibling of bin/check-versions.sh.
test_bin_sibling_owner_is_longest_stem() {
    local root out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi
    root=$(_make_bin_fixture)
    /usr/bin/touch "$root/bin/check-versions-checkers.sh" \
        "$root/tests/unit/bin/check-versions-checkers-x.sh"

    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/check-versions.sh")
    assert_equals "$root/tests/unit/bin/check-versions.sh" "$out" \
        "bin/check-versions.sh must yield both deeper suites to bin/check-versions-checkers.sh"

    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/check.sh" | command sort)
    assert_equals "$root/tests/unit/bin/check-foo.sh
$root/tests/unit/bin/check.sh" "$out" \
        "bin/check.sh must skip a suite owned two stems deeper"

    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/check-versions-checkers.sh" | command sort)
    assert_equals "$root/tests/unit/bin/check-versions-checkers-x.sh
$root/tests/unit/bin/check-versions-checkers.sh" "$out" \
        "the longest stem must collect its own exact suite and sibling"

    /usr/bin/rm -rf "$root"
}

# A case `*` matches `/`, so bin/lib/x.sh reaches the bin arm. It must map by
# its path under bin/, not its basename (which would look in tests/unit/bin/).
test_bin_nested_maps_by_relative_path() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    out=$(map_to_test "bin/lib/common.sh")
    assert_equals "$TESTS_DIR/unit/bin/lib/common.sh" "$out" \
        "bin/lib/common.sh must map to tests/unit/bin/lib/common.sh only"
}

# Extract collect_test_files (the main block's dedupe / ALL / GO_TEST step).
# Same trust boundary as _load_map_to_test above.
_load_collect_test_files() {
    local body
    _load_map_changed_files || return 1
    body=$(/usr/bin/awk '/^collect_test_files\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$RUNNER")
    [ -n "$body" ] || return 1
    eval "$body"
}

# A changed script plus its own changed suite map to the same path twice; the
# runner must run each suite once.
test_collect_dedupes_overlapping_inputs() {
    if ! _load_collect_test_files; then
        fail_test "could not extract collect_test_files from $RUNNER"
        return 0
    fi

    collect_test_files < <(command printf '%s\n' bin/check-versions.sh \
        tests/unit/bin/check-versions.sh | map_changed_files)
    assert_equals "$TESTS_DIR/unit/bin/check-versions-checkers.sh
$TESTS_DIR/unit/bin/check-versions.sh" "$(command printf '%s\n' "${TEST_FILES[@]}")" \
        "overlapping changed files must collect one entry per suite"
}

# Fed directly, with a real suite AFTER the ALL line: map_changed_files already
# stops at ALL, so going through it would hide a collect_test_files that keeps
# reading past ALL.
test_collect_sets_run_all() {
    if ! _load_collect_test_files; then
        fail_test "could not extract collect_test_files from $RUNNER"
        return 0
    fi

    collect_test_files < <(command printf '%s\n' ALL "$TESTS_DIR/unit/bin/check-versions.sh")
    assert_equals "true" "$RUN_ALL" "an ALL line must set RUN_ALL"
    assert_equals "0" "${#TEST_FILES[@]}" "input after ALL must not be collected"
}

# GO_TEST is a sentinel, not a path: it must flip RUN_GO_TESTS and never reach
# TEST_FILES. Fed directly — no current map_to_test arm emits it. Run from a
# directory holding a file literally named GO_TEST, so the -f filter cannot
# mask a missing unset of the sentinel.
test_collect_go_test_sentinel() {
    local scratch
    if ! _load_collect_test_files; then
        fail_test "could not extract collect_test_files from $RUNNER"
        return 0
    fi
    scratch=$(/usr/bin/mktemp -d)
    /usr/bin/touch "$scratch/GO_TEST"

    pushd "$scratch" >/dev/null || return 1
    collect_test_files < <(command printf '%s\n' GO_TEST "$TESTS_DIR/unit/bin/check-versions.sh")
    popd >/dev/null || return 1
    /usr/bin/rm -rf "$scratch"

    assert_equals "true" "$RUN_GO_TESTS" "the GO_TEST sentinel must set RUN_GO_TESTS"
    assert_equals "$TESTS_DIR/unit/bin/check-versions.sh" "$(command printf '%s\n' "${TEST_FILES[@]}")" \
        "the GO_TEST sentinel must not become a TEST_FILES entry"
    assert_equals "false" "$RUN_ALL" "RUN_ALL must stay false without an ALL line"
}

run_test test_runner_exports_flag "Pre-push runner exports SKIP_NETWORK_TESTS"
run_test test_framework_defines_helper "framework.sh defines network_tests_disabled"
run_test test_framework_exports_helper "framework.sh exports network_tests_disabled"
run_test test_helper_keys_on_env "Helper keys on SKIP_NETWORK_TESTS env var"
run_test test_check_versions_guards_live_tests "check-versions.sh guards live-script tests"
run_test test_version_resolution_honors_flag "version-resolution.sh honors skip flag"
run_test test_helper_enabled "network_tests_disabled true when flag=1"
run_test test_helper_dev_override "network_tests_disabled false when flag=0"
run_test test_helper_ci_path_unset "network_tests_disabled false when flag unset (CI)"
run_test test_runtime_mapping_strips_order_prefix "runtime mapping strips the NN- order prefix (#832)"
run_test test_runtime_mapping_emits_all_siblings "runtime mapping emits every sibling suite (#832)"
run_test test_runtime_mapping_unmatched_is_silent "uncovered runtime script maps to no test path (#832)"
run_test test_runtime_mapping_keeps_prefixed_suites "runtime mapping finds suites that keep the NN- prefix (#832)"
run_test test_runtime_mapping_no_duplicate_paths "runtime mapping emits no duplicate test paths (#832)"
run_test test_bin_mapping_emits_all_siblings "bin mapping emits every sibling suite (#1024)"
run_test test_collection_keeps_each_sibling_suite "runner collection keeps each sibling suite as its own path (#1024)"
run_test test_collection_stops_at_all "runner collection ends with ALL for a foundational file"
run_test test_bin_unmatched_collects_nothing "uncovered bin script maps to and collects no test path (#1024)"
run_test test_bin_sibling_skips_longer_owned_suite "bin sibling fanout skips suites a longer bin stem owns (#1031)"
run_test test_bin_sibling_owner_is_longest_stem "bin sibling ownership goes to the longest bin stem (#1031)"
run_test test_bin_nested_maps_by_relative_path "nested bin/** script maps by its path under bin/ (#1031)"
run_test test_collect_dedupes_overlapping_inputs "runner main block runs each overlapping suite once (#1031)"
run_test test_collect_sets_run_all "runner main block sets RUN_ALL and stops at ALL (#1031)"
run_test test_collect_go_test_sentinel "runner main block handles the GO_TEST sentinel (#1031)"

# Generate test report
generate_report
