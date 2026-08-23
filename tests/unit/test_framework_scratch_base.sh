#!/usr/bin/env bash
# Regression test for issue #821: test scratch space must live OUTSIDE the
# repository, on a filesystem where a write is visible to the next read.
#
# This repo is commonly mounted through virtiofs plus a bindfs FUSE overlay. On
# that stack a write is not reliably visible to an immediately-following open():
# a single-process, zero-concurrency "write a file then grep it" loop misses
# ~3/400 under tests/results and 0/400 under /tmp. Suites that kept scratch
# under the reports dir therefore reddened at random — exactly one suite per full
# run, a different suite each time, always green when re-run standalone. The
# framework now provides $TEST_SCRATCH_BASE off the repo, and the reports dir is
# reserved for reports and CI artifacts.
#
# These assertions are STRUCTURAL (location and filesystem type) rather than
# statistical. The race does not reproduce on a Linux CI runner, where the repo
# is on ordinary storage — but a regression that moved scratch back into the
# repo would still be caught there, because the property being asserted holds
# on every platform.
#
# The framework is exercised in a CHILD shell (not by calling
# init_test_framework in this process), because init_test_framework() resets the
# suite's pass/fail counters — re-running it mid-suite would corrupt this file's
# own report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

FRAMEWORK_SH="$SCRIPT_DIR/../framework.sh"

test_suite "test framework scratch base is off-repo and coherent (#821)"

# ---------------------------------------------------------------------------
# Run a fresh bash, source the framework, run init_test_framework, and emit the
# resulting state on stdout for the caller to assert against. Paths are passed
# through the environment (not interpolated into the -c string) so a repo
# checked out under an apostrophe-containing path can't break the quoting.
# ---------------------------------------------------------------------------
run_in_child() {
    local body="$1"
    /usr/bin/env -i \
        PATH="$PATH" \
        HOME="${HOME:-/tmp}" \
        TERM="dumb" \
        SKIP_DOCKER_CHECK=true \
        FRAMEWORK_SH="$FRAMEWORK_SH" \
        /bin/bash -c 'source "$FRAMEWORK_SH" >/dev/null 2>&1; init_test_framework >/dev/null 2>&1; '"$body"
}

# The scratch base must not live inside the repository.
test_scratch_base_is_outside_the_repo() {
    local out
    out=$(run_in_child '
        /usr/bin/echo "base=$TEST_SCRATCH_BASE"
        /usr/bin/echo "root=$PROJECT_ROOT"
        [ -d "$TEST_SCRATCH_BASE" ] && /usr/bin/echo "exists=yes" || /usr/bin/echo "exists=no"
    ')

    local base root
    base=$(/usr/bin/grep '^base=' <<<"$out" | /usr/bin/cut -d= -f2-)
    root=$(/usr/bin/grep '^root=' <<<"$out" | /usr/bin/cut -d= -f2-)

    assert_not_empty "$base" "TEST_SCRATCH_BASE must be set by the framework"
    assert_not_empty "$root" "PROJECT_ROOT must be set by the framework"
    assert_contains "$out" "exists=yes" "init_test_framework should create the scratch base"

    # Negative: not under the repo (the actual #821 regression).
    case "$base" in
        "$root"/*)
            fail_test "scratch base '$base' is inside the repo '$root' — see #821"
            return 0
            ;;
    esac

    # Positive counterpart: it resolves under a real tmp root, so an unexpected
    # third location (e.g. $HOME) cannot pass on the negative assertion alone.
    assert_contains "$base" "container-test-scratch" \
        "scratch base should live under the framework's own tmp parent dir"
}

# The scratch base must not sit on a filesystem with incoherent write-then-read.
test_scratch_base_is_not_on_an_incoherent_filesystem() {
    local out
    out=$(run_in_child '
        /usr/bin/echo "fstype=$(tf_fstype_of "$TEST_SCRATCH_BASE")"
        if tf_is_incoherent_fs "$TEST_SCRATCH_BASE"; then
            /usr/bin/echo "verdict=incoherent"
        else
            /usr/bin/echo "verdict=ok"
        fi
    ')

    local fstype
    fstype=$(/usr/bin/grep '^fstype=' <<<"$out" | /usr/bin/cut -d= -f2-)

    assert_not_empty "$fstype" "the framework must be able to probe the scratch filesystem type"
    assert_contains "$out" "verdict=ok" \
        "scratch base is on '$fstype', a filesystem with unreliable write-then-read (#821)"
    assert_not_contains "$out" "verdict=incoherent" \
        "scratch base must not be on a FUSE/virtiofs/network filesystem"
}

# The framework's own default setup() must also stay off the repo — guards the
# mktemp default against a future "let's keep fixtures with the reports" change.
test_default_setup_temp_dir_is_outside_the_repo() {
    local out
    out=$(run_in_child '
        setup
        /usr/bin/echo "tmp=$TEST_TEMP_DIR"
        /usr/bin/echo "root=$PROJECT_ROOT"
        teardown
    ')

    local tmp root
    tmp=$(/usr/bin/grep '^tmp=' <<<"$out" | /usr/bin/cut -d= -f2-)
    root=$(/usr/bin/grep '^root=' <<<"$out" | /usr/bin/cut -d= -f2-)

    assert_not_empty "$tmp" "default setup() must export TEST_TEMP_DIR"
    case "$tmp" in
        "$root"/*)
            fail_test "default setup() temp dir '$tmp' is inside the repo — see #821"
            return 0
            ;;
    esac

    # Positive counterpart to the negative case above: prove the path resolves
    # somewhere real, so a blank or bogus value can't pass by simply not
    # matching the repo prefix.
    assert_contains "$out" "container-test-" \
        "default setup() should create a framework-named temp dir"
}

# Anti-regeneration guard: no unit suite may build scratch paths from the
# reports directory again. This is what stops a new suite — or an agent
# following a stale example — from silently reintroducing the bug.
test_no_unit_suite_uses_the_reports_dir_for_scratch() {
    local unit_dir="$PROJECT_ROOT/tests/unit"

    # Assembled from parts so this file's own guard does not match itself.
    local banned="RESULTS"
    banned="${banned}_DIR"

    local hits=""
    hits=$(/usr/bin/grep -rn -- "$banned" "$unit_dir" 2>/dev/null || true)

    assert_equals "" "$hits" \
        "unit suites must use \$TEST_SCRATCH_BASE for scratch, not the reports dir (#821)"
}

# The docs and the skill reference are what a human or an agent copies when
# writing a NEW suite, so a stale example there regenerates the bug even while
# every existing suite is clean — and the tests/unit scan above cannot see it.
# Guard the two canonical templates: neither may assign TEST_TEMP_DIR from the
# reports dir. (This caught a real regression: the doc edits were lost in a
# rebase while the code rewrite survived.)
test_docs_do_not_teach_the_reports_dir_for_scratch() {
    # Assembled from parts so this file's own guard does not match itself.
    local banned="RESULTS"
    banned="${banned}_DIR"

    local doc
    local hits=""
    for doc in \
        "$PROJECT_ROOT/docs/development/testing.md" \
        "$PROJECT_ROOT/.claude/skills/test-framework-reference/SKILL.md"; do
        [ -f "$doc" ] || continue
        hits="$hits$(/usr/bin/grep -n "TEST_TEMP_DIR=\"\$$banned" "$doc" 2>/dev/null || true)"
    done

    assert_equals "" "$hits" \
        "doc/skill examples must show \$TEST_SCRATCH_BASE, or new suites regenerate #821"
}

run_test test_scratch_base_is_outside_the_repo "scratch base lives outside the repository"
run_test test_scratch_base_is_not_on_an_incoherent_filesystem "scratch base is not on a FUSE/virtiofs filesystem"
run_test test_default_setup_temp_dir_is_outside_the_repo "default setup() temp dir is outside the repository"
run_test test_no_unit_suite_uses_the_reports_dir_for_scratch "no unit suite uses the reports dir for scratch"
run_test test_docs_do_not_teach_the_reports_dir_for_scratch "doc and skill examples teach the scratch base"

generate_report
