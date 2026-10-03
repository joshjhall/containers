#!/usr/bin/env bash
# Unit tests for lib/runtime/42-workspace-fs-health.sh — the symlink xattr
# ELOOP diagnostic (issue #977).
#
# Split out of tests/unit/runtime/workspace-fs-health.sh in issue #980, which
# had reached 1979 lines. This section is self-contained: it is driven entirely
# through the FS_HEALTH_XATTR_PROBE seam, depends only on fixtures already
# factored into the shared helper (seed_symlinks, xattr_probe_stub,
# run_fs_health_stderr), and is referenced by none of the ignorecase,
# stale-symlink, cron, or root-re-exec sections that stay behind. The
# sibling-file shape follows the precedent set by
# workspace-fs-health-cron-entry.sh and workspace-fs-health-submodules.sh.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace FS Health Symlink xattr ELOOP Tests"

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, run_fs_health_stderr,
# seed_symlinks, xattr_probe_stub, run_test_with_setup.
# Sourced after init_test_framework — setup() reads TEST_SCRATCH_BASE.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

# ============================================================================
# Symlink xattr ELOOP diagnostic (issue #977)
# ============================================================================
# The probe DIAGNOSES and repairs nothing, so every assertion here is about what
# is said and — just as importantly — what is not. Driven through the
# FS_HEALTH_XATTR_PROBE seam: ELOOP belongs to the host mount stack and cannot
# be produced on demand inside a fixture repo.

test_xattr_eloop_is_reported() {
    # The reporting path. Without this the probe could be silent in every state
    # and the whole diagnostic would be dead code that still passes a source grep.
    seed_symlinks

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)

    assert_contains "$output" "ELOOP" \
        "An ELOOP probe result names the condition (issue #977)"
    assert_contains "$output" "977" \
        "The report cites the issue so the diagnosis is findable"
}

test_xattr_eloop_report_carries_workaround() {
    # A diagnostic that names a condition without saying what to do about it
    # leaves the reader exactly where the cryptic BuildKit error did. The
    # restart requirement is the load-bearing half: the --xattr-none overlay is
    # applied at entrypoint, so someone reading this line on a running container
    # cannot fix it in place and needs the interim workaround.
    seed_symlinks

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)

    assert_contains "$output" "RESTART" \
        "The report states that the fix applies on restart (issue #977)"
    assert_contains "$output" "120000" \
        "The report carries the symlink-removal workaround (issue #977)"
}

test_xattr_report_workaround_survives_a_path_with_spaces() {
    # The emitted workaround is a command we tell people to PASTE AND RUN as
    # root-adjacent cleanup, so "it looks right" is not enough — it has to work
    # on the paths it will meet. A tracked symlink whose path contains a space
    # is the case that separates a correct one-liner from a plausible one:
    # `print $2 | xargs rm -f` word-splits it into two nonexistent paths and
    # silently removes nothing, leaving the build still broken with no signal.
    #
    # So this RUNS the emitted line rather than pinning its tokens. A substring
    # assertion on "xargs -0" would pass just as well on a line that had been
    # reverted in some other way, and would pass on a one-liner that was
    # whitespace-safe but otherwise wrong (grep-pin-is-not-behavioral-
    # coverage.md).
    #
    # Every step below mutates PROJECT_ROOT, so refuse before the first one.
    assert_in_fixture_repo || return 0
    seed_symlinks
    command ln -s realfile.txt "$PROJECT_ROOT/spaced name.link"
    git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "spaced symlink" >/dev/null 2>&1

    local output emitted
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)

    # Lift the emitted command back out of the log line: everything after the
    # "git -C <root> ls-files" marker, with the log prefix stripped.
    emitted=$(command printf '%s\n' "$output" |
        /usr/bin/grep -F 'ls-files -s |' |
        /usr/bin/sed 's/^.*\] *//')

    assert_contains "$emitted" "ls-files" \
        "The emitted workaround line is recoverable from the report"

    # Run it for real, from the fixture repo.
    (cd "$PROJECT_ROOT" && eval "$emitted") >/dev/null 2>&1

    assert_file_not_exists "$PROJECT_ROOT/spaced name.link" \
        "The emitted workaround removes a tracked symlink whose path has a space"
    assert_file_not_exists "$PROJECT_ROOT/good.link" \
        "The emitted workaround removes the ordinary tracked symlinks too"

    # And the restore half of the documented procedure puts them back, so the
    # advice is a round trip rather than a one-way deletion.
    git -C "$PROJECT_ROOT" checkout -- . >/dev/null 2>&1
    assert_file_exists "$PROJECT_ROOT/spaced name.link" \
        "git checkout -- . restores the spaced symlink (issue #977)"
}

# The same workaround is also a copy-paste snippet in the build troubleshooting
# doc. Two hand-maintained copies drift (issue #981), and the docs copy is the
# one a user pastes mid-outage, so it gets the same treatment as the emitted
# one: executed, and compared against the emitted line.
BUILD_ISSUES_DOC="$(dirname "${BASH_SOURCE[0]}")/../../../docs/troubleshooting/build-issues.md"

# The workaround deletes every tracked symlink and the restore step is
# `git checkout -- .`, which discards uncommitted work. Pointed at the real
# checkout, either would be destructive, so refuse unless PROJECT_ROOT is the
# scratch fixture: non-empty, under TEST_TEMP_DIR, its own git toplevel, and
# not the repository this test file lives in.
assert_in_fixture_repo() {
    local real_top fixture_top
    real_top=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)
    fixture_top=$(git -C "${PROJECT_ROOT:-/nonexistent}" rev-parse --show-toplevel 2>/dev/null || true)

    if [ -z "${TEST_TEMP_DIR:-}" ] || [ -z "${PROJECT_ROOT:-}" ] ||
        [ "${PROJECT_ROOT#"$TEST_TEMP_DIR"/}" = "$PROJECT_ROOT" ] ||
        [ -z "$fixture_top" ] ||
        [ "$(cd "$PROJECT_ROOT" && pwd -P)" != "$(cd "$fixture_top" && pwd -P)" ] ||
        [ "$fixture_top" = "$real_top" ]; then
        fail_test "Refusing to run the workaround outside the scratch fixture repo (PROJECT_ROOT='${PROJECT_ROOT:-}')"
        return 1
    fi
}

# Every line of the doc that carries the workaround. Callers assert there is
# exactly one, so a second snippet fails loudly instead of being picked at random.
docs_workaround_lines() {
    /usr/bin/grep -F 'ls-files -s |' "$BUILD_ISSUES_DOC" || true
}

test_xattr_docs_workaround_survives_a_path_with_spaces() {
    # The docs copy run for real against the same spaced-symlink fixture as the
    # emitted copy above. This is what catches a docs-only regression such as
    # the mawk `printf "%s\0"` trap, which removes nothing and says nothing.
    assert_in_fixture_repo || return 0
    seed_symlinks
    command ln -s realfile.txt "$PROJECT_ROOT/spaced name.link"
    git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "spaced symlink" >/dev/null 2>&1

    local docs_line
    docs_line=$(docs_workaround_lines)

    assert_equals "1" "$(command printf '%s\n' "$docs_line" | /usr/bin/grep -c 'ls-files')" \
        "build-issues.md carries exactly one workaround line (issue #981)"

    (cd "$PROJECT_ROOT" && eval "$docs_line") >/dev/null 2>&1

    assert_file_not_exists "$PROJECT_ROOT/spaced name.link" \
        "The documented workaround removes a tracked symlink whose path has a space (issue #981)"
    assert_file_not_exists "$PROJECT_ROOT/good.link" \
        "The documented workaround removes the ordinary tracked symlinks too (issue #981)"

    git -C "$PROJECT_ROOT" checkout -- . >/dev/null 2>&1
    assert_file_exists "$PROJECT_ROOT/spaced name.link" \
        "The documented restore step puts the spaced symlink back (issue #981)"
}

test_xattr_docs_and_emitted_workaround_agree() {
    # Executing each copy proves each works today; this proves they are the SAME
    # command, so a fix applied to one copy for some quirk the fixture does not
    # exercise cannot leave the other behind. The two lines differ on purpose in
    # exactly two places — the script adds `-C <root>` and spells awk as
    # `command awk` rather than `/usr/bin/awk` — and both sit before the awk
    # invocation word. Stripping through that word leaves the field separator,
    # the awk program and the xargs stage, which must match byte for byte.
    seed_symlinks

    local output emitted docs_line
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)
    emitted=$(command printf '%s\n' "$output" |
        /usr/bin/grep -F 'ls-files -s |' |
        /usr/bin/sed 's/^.*\] *//')
    docs_line=$(docs_workaround_lines)

    # Guard the comparison against agreeing on nothing: an empty or missing
    # line on both sides would otherwise compare equal.
    assert_contains "$emitted" "ls-files -s | command awk " \
        "The emitted workaround line is recoverable from the report (issue #981)"
    assert_contains "$docs_line" "ls-files -s | /usr/bin/awk " \
        "The documented workaround line is recoverable from build-issues.md (issue #981)"

    assert_equals "${emitted#*awk }" "${docs_line#*awk }" \
        "The documented and emitted workarounds run the same awk/xargs pipeline (issue #981)"
}

test_xattr_healthy_is_silent() {
    # The complement, and the one that keeps the diagnostic useful. This script
    # is silent when it has nothing to say; a line that also appears on a
    # healthy mount is noise operators learn to scroll past, which would defeat
    # the purpose of naming the condition at all.
    seed_symlinks

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 0)" \
        run_fs_health_stderr sensitive)

    assert_not_contains "$output" "ELOOP" \
        "A healthy xattr probe reports nothing (issue #977)"
}

test_xattr_indeterminate_is_silent() {
    # Exit 2 means the probe could not determine the answer — python3 missing,
    # an unexpected errno. That is NOT evidence of the condition, and reporting
    # on it would cry wolf on every image without python3. Distinct from the
    # healthy case on purpose: the two share an outcome but not a reason, and a
    # naive `[ "$rc" != 0 ]` guard would pass the healthy test while failing
    # this one.
    seed_symlinks

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 2)" \
        run_fs_health_stderr sensitive)

    assert_not_contains "$output" "ELOOP" \
        "An indeterminate xattr probe reports nothing (issue #977)"
}

test_xattr_probe_does_not_repair() {
    # The probe must stay a diagnostic. This is not hypothetical tidiness: the
    # neighbouring repair relinks stale symlinks, and ELOOP was measured NOT to
    # respond to relinking (a symlink created seconds earlier fails identically,
    # because the condition belongs to the mount). A probe that grew a repair
    # would rewrite healthy links to no effect.
    seed_symlinks
    local before
    before=$(/usr/bin/readlink "$PROJECT_ROOT/good.link")

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)

    assert_not_contains "$output" "refreshed" \
        "The ELOOP diagnostic must not trigger a symlink repair (issue #977)"
    assert_equals "$before" "$(/usr/bin/readlink "$PROJECT_ROOT/good.link")" \
        "The ELOOP diagnostic leaves symlinks untouched (issue #977)"
}

test_xattr_eloop_does_not_fail_startup() {
    # This script must never be why a container fails to start. The condition it
    # reports here is real and unfixable in place, which makes a non-zero exit a
    # plausible-looking mistake.
    seed_symlinks

    local rc=0 probe
    probe=$(xattr_probe_stub 1)
    (
        export PROJECT_ROOT
        export FS_CASE_STATE=sensitive
        export SKIP_CASE_CHECK=false
        export SKIP_CASE_FIX=false
        export FS_HEALTH_ENV_FILE
        export FS_HEALTH_XATTR_PROBE="$probe"
        bash "$FS_HEALTH_SCRIPT"
    ) >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" \
        "An ELOOP diagnostic never fails startup (issue #977)"
}

test_xattr_probe_skips_dead_entry_and_finds_live_one() {
    # The index and the working tree can disagree, and the probe picks ONE
    # tracked symlink to test. If it keyed on whichever entry sorts first and
    # that entry were absent from disk, it would go silent while the repo is
    # still affected — a false negative, worse than no diagnostic.
    #
    # Not hypothetical: this repo's own documented #977 workaround tells people
    # to `rm -f` the tracked symlinks to get a build through, which creates
    # exactly this state.
    #
    # seed_symlinks commits broken.link, dir.link and good.link; removing the
    # alphabetically-first entry from DISK (while it stays in the index) must
    # leave the probe still finding a live one and still reporting.
    seed_symlinks
    command rm -f "$PROJECT_ROOT/broken.link"

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)

    assert_contains "$output" "ELOOP" \
        "A dead first index entry must not silence the probe (issue #977)"
}

test_xattr_probe_silent_when_every_entry_is_dead() {
    # The complement, and what keeps the fix above from over-reaching into a
    # false POSITIVE: when no tracked symlink is live on disk there is nothing
    # the condition could affect, so the walk must fall through to silence
    # rather than probing a path that is not there.
    seed_symlinks
    command rm -f "$PROJECT_ROOT/broken.link" "$PROJECT_ROOT/dir.link" \
        "$PROJECT_ROOT/good.link"

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)

    assert_not_contains "$output" "ELOOP" \
        "No live tracked symlink means no ELOOP report (issue #977)"
}

test_xattr_default_probe_runs_and_is_silent_on_healthy_fs() {
    # Every other test here injects FS_HEALTH_XATTR_PROBE, so the PRODUCTION
    # branch — the inline python3 that actually ships — is never executed by
    # them. A syntax error or a wrong errno in that heredoc would pass the whole
    # suite and only surface on a real container boot.
    #
    # The fixture repo lives on the test filesystem, which is not the affected
    # mount, so the real probe should answer healthy and say nothing. That is a
    # weaker assertion than the injected cases, but it is the one thing only
    # this test can establish: that the shipped code path RUNS, exits cleanly,
    # and stays quiet. The seam must be explicitly UNSET, not empty-string, or
    # the helper's default export would re-enter the injected branch.
    seed_symlinks

    local output rc=0
    output=$(
        unset FS_HEALTH_XATTR_PROBE
        export PROJECT_ROOT
        export FS_CASE_STATE=sensitive
        export SKIP_CASE_CHECK=false
        export SKIP_CASE_FIX=false
        export FS_HEALTH_ENV_FILE
        { bash "$FS_HEALTH_SCRIPT" >/dev/null; } 2>&1
    ) || rc=$?

    assert_equals "0" "$rc" \
        "The shipped python3 probe runs without erroring (issue #977)"
    assert_not_contains "$output" "ELOOP" \
        "The shipped probe is silent on an unaffected filesystem (issue #977)"
}

test_xattr_probe_skipped_without_tracked_symlinks() {
    # No tracked symlinks means nothing the condition could affect, so the probe
    # should not even run — let alone report. A repo with no symlinks builds
    # fine on this mount, and saying otherwise would be a false alarm.
    #
    # PROJECT_ROOT is seeded with a commit but deliberately NO symlinks.
    echo "content" >"$PROJECT_ROOT/plain.txt"
    git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "no symlinks" >/dev/null 2>&1

    local output
    output=$(FS_HEALTH_XATTR_PROBE="$(xattr_probe_stub 1)" \
        run_fs_health_stderr sensitive)

    assert_not_contains "$output" "ELOOP" \
        "A repo with no tracked symlinks produces no ELOOP report (issue #977)"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup test_xattr_eloop_is_reported "ELOOP probe result names the condition (#977)"
run_test_with_setup test_xattr_eloop_report_carries_workaround "ELOOP report carries restart + workaround (#977)"
run_test_with_setup test_xattr_report_workaround_survives_a_path_with_spaces "The emitted workaround handles a spaced path (#977)"
run_test_with_setup test_xattr_docs_workaround_survives_a_path_with_spaces "The documented workaround handles a spaced path (#981)"
run_test_with_setup test_xattr_docs_and_emitted_workaround_agree "Documented and emitted workarounds agree (#981)"
run_test_with_setup test_xattr_healthy_is_silent "Healthy xattr probe stays silent (#977)"
run_test_with_setup test_xattr_indeterminate_is_silent "Indeterminate xattr probe stays silent (#977)"
run_test_with_setup test_xattr_probe_does_not_repair "ELOOP diagnostic repairs nothing (#977)"
run_test_with_setup test_xattr_eloop_does_not_fail_startup "ELOOP diagnostic never fails startup (#977)"
run_test_with_setup test_xattr_default_probe_runs_and_is_silent_on_healthy_fs "The shipped python3 probe runs and stays quiet (#977)"
run_test_with_setup test_xattr_probe_skips_dead_entry_and_finds_live_one "A dead index entry does not silence the probe (#977)"
run_test_with_setup test_xattr_probe_silent_when_every_entry_is_dead "No live tracked symlink, no ELOOP report (#977)"
run_test_with_setup test_xattr_probe_skipped_without_tracked_symlinks "No tracked symlinks, no ELOOP report (#977)"

# Generate test report
generate_report
