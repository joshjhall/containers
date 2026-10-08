#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/setup-bindfs.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Setup Bindfs Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/lib/setup-bindfs.sh"

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "setup-bindfs.sh exists"
}

test_script_executable() {
    assert_executable "$SOURCE_FILE" "setup-bindfs.sh is executable"
}

test_defines_parse_bindfs_skip_paths() {
    assert_file_contains "$SOURCE_FILE" "parse_bindfs_skip_paths()" \
        "Defines parse_bindfs_skip_paths function"
}

test_defines_probe_mount_needs_fix() {
    assert_file_contains "$SOURCE_FILE" "probe_mount_needs_fix()" \
        "Defines probe_mount_needs_fix function"
}

test_defines_apply_bindfs_overlay() {
    assert_file_contains "$SOURCE_FILE" "apply_bindfs_overlay()" \
        "Defines apply_bindfs_overlay function"
}

test_defines_setup_bindfs_overlays() {
    assert_file_contains "$SOURCE_FILE" "setup_bindfs_overlays()" \
        "Defines setup_bindfs_overlays function"
}

test_bindfs_enabled_default() {
    assert_file_contains "$SOURCE_FILE" 'BINDFS_ENABLED="${BINDFS_ENABLED:-auto}"' \
        "BINDFS_ENABLED defaults to auto"
}

test_dev_fuse_check() {
    assert_file_contains "$SOURCE_FILE" "/dev/fuse" \
        "Script checks for /dev/fuse availability"
}

test_fuse_fstype_skip() {
    assert_file_contains "$SOURCE_FILE" '*fuse*' \
        "Script skips FUSE filesystem types"
}

test_virtiofs_detection() {
    assert_file_contains "$SOURCE_FILE" "virtiofs" \
        "Script detects virtiofs filesystem type"
}

test_grpcfuse_detection() {
    assert_file_contains "$SOURCE_FILE" "grpcfuse" \
        "Script detects grpcfuse filesystem type"
}

test_osxfs_detection() {
    assert_file_contains "$SOURCE_FILE" "osxfs" \
        "Script detects osxfs filesystem type"
}

test_fakeowner_detection() {
    assert_file_contains "$SOURCE_FILE" "fakeowner" \
        "Script detects fakeowner filesystem type"
}

test_skip_paths_comma_split() {
    assert_file_contains "$SOURCE_FILE" "IFS=',' read -ra" \
        "Script comma-splits BINDFS_SKIP_PATHS"
}

test_probe_file_pattern() {
    assert_file_contains "$SOURCE_FILE" ".bindfs-probe-" \
        "Script uses .bindfs-probe-PID pattern"
}

test_bindfs_force_user_option() {
    assert_file_contains "$SOURCE_FILE" "--force-user=" \
        "Script passes --force-user to bindfs"
}

test_bindfs_create_for_group_option() {
    assert_file_contains "$SOURCE_FILE" "--create-for-group=" \
        "Script passes --create-for-group to bindfs"
}

test_bindfs_allow_other_option() {
    assert_file_contains "$SOURCE_FILE" "-o allow_other" \
        "Script passes -o allow_other to bindfs"
}

test_fuse_hidden_cleanup() {
    assert_file_contains "$SOURCE_FILE" ".fuse_hidden" \
        "Script handles .fuse_hidden file cleanup"
}

# The boot pass delegates the sweep to the shared GC rather than carrying its own
# copy. The fuser guard and the walk now live in lib/runtime/fuse-cleanup.sh and
# are tested in tests/unit/runtime/fuse-cleanup.sh (issue #948).
test_delegates_to_shared_cleanup() {
    assert_file_contains "$SOURCE_FILE" "fuse-cleanup" \
        "Script delegates to the shared fuse-cleanup GC"
    assert_file_contains "$SOURCE_FILE" "FUSE_CLEANUP_FALLBACK_ROOT" \
        "Script passes /workspace as the fallback root"
}

test_no_duplicate_sweep() {
    # The boot copy's hardcoded /workspace root is what made it effectively
    # maxdepth 2 relative to the mount — strictly weaker than the cron pass it
    # complements. A reappearing walk here means the copy came back.
    assert_file_not_contains "$SOURCE_FILE" "maxdepth" \
        "Boot pass carries no depth-bounded walk of its own (issue #948)"
}

# The missing-GC branch must SAY something (issue #951). Before this the -x test
# had no else, so a broken install disabled the boot leg permanently while
# looking identical to a clean run — the invisible-stranded-files failure #948
# was filed against, reintroduced through its own fix.
test_missing_gc_is_reported() {
    assert_file_contains "$SOURCE_FILE" "FUSE cleanup skipped" \
        "Boot pass warns when the shared GC is missing (issue #951)"
}

test_skip_map_associative_array() {
    assert_file_contains "$SOURCE_FILE" "BINDFS_SKIP_MAP" \
        "Script uses BINDFS_SKIP_MAP associative array"
}

test_dev_fuse_warning() {
    assert_file_contains "$SOURCE_FILE" "/dev/fuse not available" \
        "Script warns when /dev/fuse is not available"
}

test_applied_counter() {
    assert_file_contains "$SOURCE_FILE" "BINDFS_APPLIED" \
        "Script tracks count of applied overlays"
}

# ============================================================================
# Functional Tests
# ============================================================================

test_parse_skip_paths_sets_map() {
    (
        # Source the script to get the function
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS="/workspace/a,/workspace/b, /workspace/c "
        parse_bindfs_skip_paths

        # Check all three keys are set
        [ -n "${BINDFS_SKIP_MAP["/workspace/a"]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP["/workspace/b"]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP["/workspace/c"]+_}" ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths populates BINDFS_SKIP_MAP from env"
}

test_parse_skip_paths_empty() {
    (
        source "$SOURCE_FILE"

        unset BINDFS_SKIP_PATHS 2>/dev/null || true
        parse_bindfs_skip_paths

        # Map should be empty (0 keys)
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 0 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths handles empty BINDFS_SKIP_PATHS"
}

test_parse_skip_paths_multiple_spaces() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS="  /cache  ,   /tmp   "
        parse_bindfs_skip_paths

        [ -n "${BINDFS_SKIP_MAP["/cache"]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP["/tmp"]+_}" ] || exit 1
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 2 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths trims multiple leading/trailing spaces"
}

test_parse_skip_paths_tabs() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS=$'\t/cache\t,\t/tmp'
        parse_bindfs_skip_paths

        [ -n "${BINDFS_SKIP_MAP["/cache"]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP["/tmp"]+_}" ] || exit 1
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 2 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths trims tab characters"
}

test_parse_skip_paths_mixed_whitespace() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS=$' \t /cache \t , \t /var \t '
        parse_bindfs_skip_paths

        [ -n "${BINDFS_SKIP_MAP["/cache"]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP["/var"]+_}" ] || exit 1
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 2 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths trims mixed spaces and tabs"
}

test_parse_skip_paths_whitespace_only_fields() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS=$'  , \t ,  '
        parse_bindfs_skip_paths

        [ "${#BINDFS_SKIP_MAP[@]}" -eq 0 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths ignores whitespace-only fields"
}

test_probe_fuse_fstype_skipped() {
    (
        source "$SOURCE_FILE"

        declare -gA BINDFS_SKIP_MAP=()
        # A fuse fstype should return 1 (skip)
        probe_mount_needs_fix "/workspace/test" "fuse.bindfs" "auto" >/dev/null 2>&1
    )
    assert_not_equals "0" "$?" "probe_mount_needs_fix returns 1 for fuse fstype"
}

test_probe_true_mode_always_applies() {
    (
        source "$SOURCE_FILE"

        declare -gA BINDFS_SKIP_MAP=()
        # In "true" mode with non-fuse fstype, should return 0 (apply)
        probe_mount_needs_fix "/workspace/test" "ext4" "true" >/dev/null 2>&1
    )
    assert_equals "0" "$?" "probe_mount_needs_fix returns 0 in true mode"
}

# Functional counterpart to test_missing_gc_is_reported: prove the else branch
# actually fires and that reporting did not turn a broken install into a boot
# failure. A missing GC is degraded cleanup, not a fatal startup error, so
# setup_bindfs_overlays must still return 0 (issue #951).
test_missing_gc_warns_and_succeeds() {
    local output
    output=$(
        source "$SOURCE_FILE"
        _FUSE_CLEANUP_GC=/nonexistent/fuse-cleanup
        BINDFS_ENABLED=false setup_bindfs_overlays 2>&1
    )
    local rc=$?

    assert_equals "0" "$rc" \
        "Missing GC does not fail startup (issue #951)"
    assert_contains "$output" "missing or not executable" \
        "Missing GC produces a visible warning (issue #951)"
}

test_present_gc_warns_nothing() {
    # The complement: a working GC must stay quiet. A warning that fires on the
    # healthy path is noise operators learn to ignore, which would defeat #951.
    local stub_dir stub output
    stub_dir=$(mktemp -d)
    stub="$stub_dir/fuse-cleanup"
    command printf '%s\n' '#!/bin/bash' 'echo 0' >"$stub"
    chmod +x "$stub"

    output=$(
        source "$SOURCE_FILE"
        _FUSE_CLEANUP_GC="$stub"
        BINDFS_ENABLED=false setup_bindfs_overlays 2>&1
    )
    command rm -rf "$stub_dir"

    assert_not_contains "$output" "missing or not executable" \
        "Healthy GC produces no missing-binary warning (issue #951)"
}

# ============================================================================
# Boot-pass delegation (issue #952)
# ============================================================================
# setup_bindfs_overlays runs the shared GC, parses its stdout into a count, and
# prints a message behind a `-gt 0` guard. Until #952 that was only string-matched
# against the source: the parse and the guard never executed. These drive them.
#
# _FUSE_CLEANUP_GC makes the call point injectable, so each case is just a stub
# that prints (or fails) in a particular way. BINDFS_ENABLED=false keeps the
# overlay half of the function out of the picture.

# Write an executable fuse-cleanup stub whose body is the given lines, echoing
# its path. The caller owns cleanup of its parent directory (dirname of the
# returned path). Kept out of the repo tree on purpose — the workspace is
# FUSE-mounted here and loses write-then-read coherency.
stub_fuse_cleanup_bin() {
    local stub_dir stub
    stub_dir=$(mktemp -d)
    stub="$stub_dir/fuse-cleanup"
    command printf '%s\n' '#!/bin/bash' "$@" >"$stub"
    command chmod +x "$stub"
    echo "$stub"
}

# Run setup_bindfs_overlays against a stub GC, merging stderr into stdout.
run_boot_pass() {
    local stub="$1"
    (
        source "$SOURCE_FILE"
        # The seam is reassigned AFTER sourcing, which is what the file's own
        # unconditional assignment requires (#968).
        _FUSE_CLEANUP_GC="$stub"
        BINDFS_ENABLED=false setup_bindfs_overlays 2>&1
    )
}

test_boot_pass_reports_cleaned_count() {
    # Asserts the COUNT, not merely the phrase. Matching "Cleaned up" alone would
    # pass against an implementation that printed a hardcoded string and threw
    # the GC's stdout away — which is exactly the parse this test exists for.
    local stub output
    stub=$(stub_fuse_cleanup_bin 'echo 7')

    output=$(run_boot_pass "$stub")
    command rm -rf "$(dirname "$stub")"

    assert_contains "$output" "Cleaned up 7 stale" \
        "Boot pass reports the count the GC printed (issue #952)"
}

test_boot_pass_silent_when_nothing_cleaned() {
    # The `-gt 0` guard. Without it every clean boot — the overwhelmingly common
    # case — prints "Cleaned up 0 stale .fuse_hidden file(s)", which is the kind
    # of startup noise operators learn to scroll past.
    local stub output
    stub=$(stub_fuse_cleanup_bin 'echo 0')

    output=$(run_boot_pass "$stub")
    command rm -rf "$(dirname "$stub")"

    assert_not_contains "$output" "Cleaned up" \
        "Boot pass says nothing when the GC cleaned nothing (issue #952)"
}

test_boot_pass_tolerates_gc_failure() {
    # A GC that exits non-zero with no stdout drives the `|| echo 0` fallback.
    # Cleanup failing is degraded cleanup, never a fatal startup error — the same
    # judgement #951 made for a missing binary.
    local stub output rc=0
    stub=$(stub_fuse_cleanup_bin 'exit 1')

    output=$(run_boot_pass "$stub") || rc=$?
    command rm -rf "$(dirname "$stub")"

    assert_equals "0" "$rc" \
        "A failing GC does not fail startup (issue #952)"
    assert_not_contains "$output" "Cleaned up" \
        "A failing GC reports no cleaned files"
}

test_boot_pass_tolerates_nonnumeric_count() {
    # Why the comparison carries its own `2>/dev/null`: a GC that printed
    # something non-numeric would otherwise make bash emit "integer expression
    # expected" onto the boot log. Under `set -e` in the entrypoint the failed
    # comparison is also the last command of the branch, so this is the case that
    # keeps a malformed count from reading as a startup failure.
    local stub output rc=0
    stub=$(stub_fuse_cleanup_bin 'echo not-a-number')

    output=$(run_boot_pass "$stub") || rc=$?
    command rm -rf "$(dirname "$stub")"

    assert_equals "0" "$rc" \
        "A non-numeric count does not fail startup (issue #952)"
    assert_not_contains "$output" "Cleaned up" \
        "A non-numeric count reports no cleaned files"
    assert_not_contains "$output" "integer expression" \
        "A non-numeric count is silent — no bash diagnostic on the boot log"
}

# ============================================================================
# Testing-seam neutralization (issue #953)
# ============================================================================
# The boot pass invokes the GC root-privileged and the GC's walk has no depth
# bound, so whatever names its roots names the scope of a recursive `rm -f`.
# FUSE_CLEANUP_ROOTS / FUSE_CLEANUP_FINDMNT / FUSE_CLEANUP_FALLBACK_ROOT are
# testing seams that each redirect that walk, so the boot pass unsets them.
#
# These tests pin the value OBSERVED AT THE GC, not the source text. An
# `assert_file_contains "$SOURCE_FILE" "unset"` would pass against an unset of
# the wrong variable, in the wrong order (eating this leg's own /workspace
# fallback), or outside the subshell that wraps the call — every way this can be
# got wrong is a way that grep still passes.
#
# Reporting goes through a FILE rather than stderr because the boot pass sends
# the GC's stderr to /dev/null, and through a file rather than stdout because
# stdout is the cleaned count the caller parses.

# Echo the value the GC actually saw for each named variable, one per line in
# argument order, having run the boot pass with the environment the caller
# exported. Prints UNSET for a variable that did not arrive.
observe_gc_env() {
    local var stub obs
    local -a report=()
    obs=$(mktemp)
    for var in "$@"; do
        report+=("command printf '%s\\n' \"\${$var:-UNSET}\" >>'$obs'")
    done
    stub=$(stub_fuse_cleanup_bin "${report[@]}" 'echo 0')

    run_boot_pass "$stub" >/dev/null 2>&1
    command rm -rf "$(dirname "$stub")"

    command cat "$obs"
    command rm -f "$obs"
}

test_boot_pass_drops_injected_roots() {
    local seen
    seen=$(FUSE_CLEANUP_ROOTS=/etc observe_gc_env FUSE_CLEANUP_ROOTS)

    assert_equals "UNSET" "$seen" \
        "Boot pass drops an injected FUSE_CLEANUP_ROOTS (issue #953)"
}

test_boot_pass_drops_injected_findmnt() {
    # The second path to the same arbitrary root: a discovery stub printing /
    # hands the GC the whole filesystem without ROOTS being set at all.
    local seen
    seen=$(FUSE_CLEANUP_FINDMNT=/tmp/evil-findmnt observe_gc_env FUSE_CLEANUP_FINDMNT)

    assert_equals "UNSET" "$seen" \
        "Boot pass drops an injected FUSE_CLEANUP_FINDMNT (issue #953)"
}

test_boot_pass_overrides_injected_fallback_root() {
    # FALLBACK_ROOT is the one that must be dropped AND replaced. Asserting
    # merely "not /etc" would pass against an unset that also ate this leg's own
    # assignment, which would silently disable the stranded-file sweep that is
    # the boot pass's unique job. So assert the value that must arrive.
    local seen
    seen=$(FUSE_CLEANUP_FALLBACK_ROOT=/etc observe_gc_env FUSE_CLEANUP_FALLBACK_ROOT)

    assert_equals "/workspace" "$seen" \
        "Boot pass replaces an injected fallback root with /workspace (issue #953)"
}

test_boot_pass_preserves_disable() {
    # The complement that keeps the neutralization from over-reaching:
    # FUSE_CLEANUP_DISABLE is a documented operator control, not a seam. If the
    # unset list were widened by name prefix rather than by what redirects the
    # walk, operators would lose the documented way to turn cleanup off.
    local seen
    seen=$(FUSE_CLEANUP_DISABLE=true observe_gc_env FUSE_CLEANUP_DISABLE)

    assert_equals "true" "$seen" \
        "Boot pass still passes FUSE_CLEANUP_DISABLE through (issue #953)"
}

test_boot_pass_neutralizes_all_seams_together() {
    # The per-variable tests above each inject ONE seam, so together they pin
    # each name but not the set: production clears all three with a single
    # unset, and a refactor splitting it per variable (say, to special-case
    # FALLBACK_ROOT's reassignment) could drop one while every single-seam test
    # stays green. Injecting all three at once pins the set as one observation.
    # FALLBACK_ROOT arrives as this leg's own /workspace, not UNSET.
    local seen expected
    seen=$(FUSE_CLEANUP_ROOTS=/etc \
        FUSE_CLEANUP_FINDMNT=/tmp/evil-findmnt \
        FUSE_CLEANUP_FALLBACK_ROOT=/etc \
        observe_gc_env FUSE_CLEANUP_ROOTS FUSE_CLEANUP_FINDMNT FUSE_CLEANUP_FALLBACK_ROOT)
    expected=$(command printf '%s\n' UNSET UNSET /workspace)

    assert_equals "$expected" "$seen" \
        "Boot pass neutralizes all three seams injected together (issue #970)"
}

test_boot_pass_unset_does_not_leak_to_caller() {
    # The unset lives in a command-substitution subshell, so it must not disturb
    # the entrypoint's own environment. A bare `unset` before the call would
    # strip the variables for everything that runs after setup_bindfs_overlays.
    #
    # This deliberately does NOT go through run_boot_pass: that helper wraps the
    # call in its own ( ) subshell, which would swallow a leaked unset and keep
    # this test green against exactly the bug it names. The function is called
    # in the same shell that reads the variables back afterwards.
    local stub after expected
    stub=$(stub_fuse_cleanup_bin 'echo 0')

    after=$(
        export FUSE_CLEANUP_ROOTS=/etc
        export FUSE_CLEANUP_FINDMNT=/tmp/evil-findmnt
        export FUSE_CLEANUP_FALLBACK_ROOT=/etc
        # shellcheck source=/dev/null
        source "$SOURCE_FILE"
        _FUSE_CLEANUP_GC="$stub"
        BINDFS_ENABLED=false setup_bindfs_overlays >/dev/null 2>&1
        command printf '%s\n' "${FUSE_CLEANUP_ROOTS:-UNSET}" \
            "${FUSE_CLEANUP_FINDMNT:-UNSET}" "${FUSE_CLEANUP_FALLBACK_ROOT:-UNSET}"
    )
    command rm -rf "$(dirname "$stub")"
    expected=$(command printf '%s\n' /etc /tmp/evil-findmnt /etc)

    assert_equals "$expected" "$after" \
        "Neutralization of all three seams is scoped to the GC call, not the caller's environment"
}

# ============================================================================
# The GC binary is not an env input (issue #968)
# ============================================================================
# FUSE_CLEANUP_BIN used to name the binary this ROOT-PRIVILEGED pass executes.
# These pin which binary actually RAN, via marker files, not the source text:
# an `assert_file_not_contains "FUSE_CLEANUP_BIN"` would pass against a leg that
# read the same override under any other name.

test_sourcing_pins_canonical_gc() {
    # The seam variable is assigned unconditionally at source time, so neither
    # the old public name nor an inherited copy of the internal one survives.
    local seen
    seen=$(
        export FUSE_CLEANUP_BIN=/tmp/evil-gc
        export _FUSE_CLEANUP_GC=/tmp/evil-gc
        # shellcheck source=/dev/null
        source "$SOURCE_FILE"
        command printf '%s' "$_FUSE_CLEANUP_GC"
    )

    assert_equals "/usr/local/bin/fuse-cleanup" "$seen" \
        "Sourcing pins the GC path regardless of inherited env (issue #968)"
}

test_boot_pass_ignores_injected_bin() {
    # The injected stub is a fully working GC that would be run if anything
    # still honored the env var, so "did not run" is decided by its marker
    # alone — not by a missing-binary branch masking the call.
    local tmpdir evil good output
    tmpdir=$(mktemp -d)
    evil=$(stub_fuse_cleanup_bin "command touch '$tmpdir/evil-ran'" 'echo 0')
    good=$(stub_fuse_cleanup_bin "command touch '$tmpdir/seam-ran'" 'echo 0')

    output=$(
        export FUSE_CLEANUP_BIN="$evil"
        # shellcheck source=/dev/null
        source "$SOURCE_FILE"
        _FUSE_CLEANUP_GC="$good"
        BINDFS_ENABLED=false setup_bindfs_overlays 2>&1
    )

    assert_file_not_exists "$tmpdir/evil-ran" \
        "Boot pass never executes an injected FUSE_CLEANUP_BIN (issue #968)"
    assert_file_exists "$tmpdir/seam-ran" \
        "Boot pass still runs the pinned GC (issue #968)"
    assert_contains "$output" "FUSE_CLEANUP_BIN is ignored" \
        "Boot pass warns that FUSE_CLEANUP_BIN is ignored (issue #968)"
    assert_not_contains "$output" "$evil" \
        "The warning does not echo the injected value (issue #968)"
    command rm -rf "$tmpdir" "$(dirname "$evil")" "$(dirname "$good")"
}

test_boot_pass_no_bin_warning_when_unset() {
    # The complement: the warning must not fire on a clean environment, or it
    # becomes startup noise on every boot.
    local stub output
    stub=$(stub_fuse_cleanup_bin 'echo 0')

    output=$(
        unset FUSE_CLEANUP_BIN
        run_boot_pass "$stub"
    )
    command rm -rf "$(dirname "$stub")"

    assert_not_contains "$output" "FUSE_CLEANUP_BIN is ignored" \
        "No ignored-variable warning when FUSE_CLEANUP_BIN is unset (issue #968)"
}

# ============================================================================
# Overlay argv (issue #977)
# ============================================================================
# apply_bindfs_overlay's ONLY externally visible effect is the argv it hands to
# bindfs, and run_privileged is a global supplied by entrypoint.sh — so a stub
# that records its arguments is the seam that makes the real function's real
# output assertable.
#
# These drive the function rather than grepping the source for "--xattr-none".
# A grep-pin passes just as happily on the flag sitting in a comment or on a
# branch that never executes (.claude/memory/grep-pin-is-not-behavioral-
# coverage.md) — and this file's comment block for #977 mentions the flag
# repeatedly, so a source grep here would be actively misleading: it would stay
# green after someone deleted the flag from the command itself.

# Run apply_bindfs_overlay against a recording run_privileged, echoing the
# argv it was handed.
capture_overlay_argv() {
    (
        source "$SOURCE_FILE"

        run_privileged() { command printf '%s\n' "$*"; }

        # Read by apply_bindfs_overlay, which was sourced above — shellcheck
        # cannot see across that boundary.
        # shellcheck disable=SC2034
        BINDFS_CAN_SUDO=true
        # shellcheck disable=SC2034
        USERNAME=testuser
        # shellcheck disable=SC2034
        BINDFS_UID=1234
        # shellcheck disable=SC2034
        BINDFS_GID=5678

        apply_bindfs_overlay /workspace/probe
    )
}

test_overlay_passes_xattr_none() {
    # The #977 fix: without --xattr-none, bindfs relays the lower layer's ELOOP
    # when listing a symlink's xattrs, and BuildKit's context sender aborts every
    # `docker build` from the repo root.
    local argv
    argv=$(capture_overlay_argv)

    assert_contains "$argv" "--xattr-none" \
        "Overlay argv carries --xattr-none (issue #977)"
}

test_overlay_does_not_pass_xattr_ro() {
    # --xattr-ro is the plausible-looking wrong answer: it was measured against
    # the real mount and STILL relays ELOOP for symlinks (only regular files
    # answer). Pinning its absence keeps a future "less drastic" substitution
    # from silently restoring the build failure.
    local argv
    argv=$(capture_overlay_argv)

    assert_not_contains "$argv" "--xattr-ro" \
        "Overlay does not substitute the ineffective --xattr-ro (issue #977)"
}

test_overlay_keeps_permission_flags() {
    # The xattr flag must not have displaced the permission mapping that is the
    # overlay's original reason to exist. Asserting the whole argv means a
    # regression in either direction fails here.
    local argv
    argv=$(capture_overlay_argv)

    assert_contains "$argv" "--force-user=testuser" \
        "Overlay still forces the user"
    assert_contains "$argv" "--create-for-user=1234" \
        "Overlay still maps the creating uid"
    assert_contains "$argv" "-o allow_other" \
        "Overlay still passes allow_other"
    assert_contains "$argv" "/workspace/probe /workspace/probe" \
        "Overlay still mounts the target onto itself"
}

test_probe_skips_listed_path() {
    (
        source "$SOURCE_FILE"

        declare -gA BINDFS_SKIP_MAP=(["/workspace/skip"]=1)
        probe_mount_needs_fix "/workspace/skip" "ext4" "true" >/dev/null 2>&1
    )
    assert_not_equals "0" "$?" "probe_mount_needs_fix skips paths in BINDFS_SKIP_MAP"
}

# ============================================================================
# Run all tests

# ============================================================================
# Scoped sudo (#996): the orchestrator's BINDFS_CAN_SUDO follows what sudo
# actually permits for bindfs, not whether `sudo -n true` succeeds. Drives
# setup_bindfs_overlays with stubbed findmnt/bindfs/sudo and a recording
# apply_bindfs_overlay, then reads BINDFS_CAN_SUDO as the apply step saw it.
# $1 = "allow" (scoped grant includes bindfs *) or "deny" (nothing allowed)
# ============================================================================
bindfs_can_sudo_under() {
    local mode="$1" stub_dir
    stub_dir=$(command mktemp -d)
    command printf '#!/bin/bash\necho "/workspace/probe ext4"\n' >"$stub_dir/findmnt"
    command printf '#!/bin/bash\nexit 0\n' >"$stub_dir/bindfs"
    # `true` is always refused, as under the scoped grant.
    command cat >"$stub_dir/sudo" <<EOF
#!/bin/bash
[ "\${1:-}" = "-n" ] && shift
[ "\${1:-}" = "-l" ] && shift
[ "$mode" = "allow" ] && [ "\${1:-}" = "bindfs" ] && exit 0
exit 1
EOF
    command chmod +x "$stub_dir"/*
    (
        export BASH_ENV=""
        export PATH="$stub_dir:$PATH"
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/runtime/lib/privileged.sh"
        source "$SOURCE_FILE"
        # Read by the sourced orchestrator — shellcheck can't see across it.
        # shellcheck disable=SC2034
        RUNNING_AS_ROOT=false
        # shellcheck disable=SC2034
        USERNAME=$(/usr/bin/id -un)
        probe_mount_needs_fix() { return 0; }
        apply_bindfs_overlay() {
            command printf 'can_sudo=%s\n' "$BINDFS_CAN_SUDO"
            return 1
        }
        _FUSE_CLEANUP_GC=/nonexistent
        BINDFS_ENABLED=true setup_bindfs_overlays 2>/dev/null
    ) | command grep -o 'can_sudo=[a-z]*'
    command rm -rf "$stub_dir"
}

test_scoped_sudo_enables_bindfs() {
    if [ ! -e /dev/fuse ]; then
        skip_test "/dev/fuse not present; orchestrator never reaches the sudo probe"
        return 0
    fi
    assert_equals "can_sudo=true" "$(bindfs_can_sudo_under allow)" \
        "Scoped grant permitting bindfs enables the overlay (#996)"
    assert_equals "can_sudo=false" "$(bindfs_can_sudo_under deny)" \
        "No bindfs grant leaves the overlay disabled"
}

# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_script_executable "Script is executable"
run_test test_defines_parse_bindfs_skip_paths "Defines parse_bindfs_skip_paths"
run_test test_defines_probe_mount_needs_fix "Defines probe_mount_needs_fix"
run_test test_defines_apply_bindfs_overlay "Defines apply_bindfs_overlay"
run_test test_defines_setup_bindfs_overlays "Defines setup_bindfs_overlays"
run_test test_bindfs_enabled_default "BINDFS_ENABLED defaults to auto"
run_test test_dev_fuse_check "Checks /dev/fuse availability"
run_test test_fuse_fstype_skip "Skips fuse filesystem types"
run_test test_virtiofs_detection "Detects virtiofs"
run_test test_grpcfuse_detection "Detects grpcfuse"
run_test test_osxfs_detection "Detects osxfs"
run_test test_fakeowner_detection "Detects fakeowner"
run_test test_skip_paths_comma_split "Comma-splits BINDFS_SKIP_PATHS"
run_test test_probe_file_pattern "Uses .bindfs-probe-PID pattern"
run_test test_bindfs_force_user_option "Passes --force-user to bindfs"
run_test test_bindfs_create_for_group_option "Passes --create-for-group to bindfs"
run_test test_bindfs_allow_other_option "Passes -o allow_other to bindfs"
run_test test_fuse_hidden_cleanup "Handles .fuse_hidden cleanup"
run_test test_delegates_to_shared_cleanup "Delegates to the shared fuse-cleanup GC"
run_test test_no_duplicate_sweep "Boot pass does not duplicate the sweep"
run_test test_missing_gc_is_reported "Warns when the shared GC is missing"
run_test test_skip_map_associative_array "Uses BINDFS_SKIP_MAP"
run_test test_dev_fuse_warning "Warns when /dev/fuse not available"
run_test test_applied_counter "Tracks applied overlay count"

# Functional tests
run_test test_parse_skip_paths_sets_map "parse_bindfs_skip_paths populates map"
run_test test_parse_skip_paths_empty "parse_bindfs_skip_paths handles empty input"
run_test test_probe_fuse_fstype_skipped "probe_mount_needs_fix skips fuse fstype"
run_test test_probe_true_mode_always_applies "probe_mount_needs_fix applies in true mode"
run_test test_probe_skips_listed_path "probe_mount_needs_fix skips listed paths"
run_test test_missing_gc_warns_and_succeeds "Missing GC warns but does not fail startup"
run_test test_present_gc_warns_nothing "Healthy GC stays quiet"

# Boot-pass delegation (#952)
run_test test_boot_pass_reports_cleaned_count "Boot pass reports the GC's count (#952)"
run_test test_boot_pass_silent_when_nothing_cleaned "Boot pass is silent on a zero count"
run_test test_boot_pass_tolerates_gc_failure "Boot pass tolerates a failing GC"
run_test test_boot_pass_tolerates_nonnumeric_count "Boot pass tolerates a non-numeric count"

# Testing-seam neutralization (#953)
run_test test_boot_pass_drops_injected_roots "Boot pass drops injected FUSE_CLEANUP_ROOTS (#953)"
run_test test_boot_pass_drops_injected_findmnt "Boot pass drops injected FUSE_CLEANUP_FINDMNT (#953)"
run_test test_boot_pass_overrides_injected_fallback_root "Boot pass replaces an injected fallback root (#953)"
run_test test_boot_pass_preserves_disable "Boot pass preserves FUSE_CLEANUP_DISABLE (#953)"
run_test test_boot_pass_neutralizes_all_seams_together "Boot pass neutralizes all three seams together (#970)"
run_test test_boot_pass_unset_does_not_leak_to_caller "Neutralization does not leak to the caller (#953)"

# The GC binary is not an env input (#968)
run_test test_sourcing_pins_canonical_gc "Sourcing pins the canonical GC path (#968)"
run_test test_boot_pass_ignores_injected_bin "Boot pass ignores and warns on FUSE_CLEANUP_BIN (#968)"
run_test test_boot_pass_no_bin_warning_when_unset "Boot pass stays quiet when FUSE_CLEANUP_BIN is unset (#968)"

# Overlay argv (#977)
run_test test_overlay_passes_xattr_none "Overlay passes --xattr-none (#977)"
run_test test_overlay_does_not_pass_xattr_ro "Overlay avoids the ineffective --xattr-ro (#977)"
run_test test_overlay_keeps_permission_flags "Overlay keeps its permission flags (#977)"
run_test test_scoped_sudo_enables_bindfs "Scoped sudo enables bindfs overlay (#996)"

# Generate test report
generate_report
