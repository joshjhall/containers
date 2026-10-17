#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/fix-cache-permissions.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Fix Cache Permissions Tests"

# Helper to set up the environment expected by fix_cache_permissions
setup_cache_env() {
    RUNNING_AS_ROOT="${1:-false}"
    USERNAME="${2:-testuser}"
    export RUNNING_AS_ROOT USERNAME
}

# ============================================================================
# Test: fix_cache_permissions when /cache does not exist
# ============================================================================
test_fix_cache_no_cache_dir() {
    # Source the script to get the function
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"

    setup_cache_env "false" "testuser"

    # Ensure /cache does not exist in the test (it shouldn't in CI)
    # The function checks [ -d "/cache" ] || return 0
    # We can't easily mock the path, but we can verify behavior by
    # checking the function returns 0 when /cache doesn't exist
    if [ ! -d "/cache" ]; then
        fix_cache_permissions
        assert_equals "0" "$?" "Returns 0 when /cache does not exist"
    else
        skip_test "/cache exists on this system, cannot test no-cache path"
    fi
}

# ============================================================================
# Test: fix_cache_permissions outputs correct messages
# ============================================================================
test_fix_cache_output_no_root() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"

    setup_cache_env "false" "testuser"

    # Create a temporary /cache-like directory for testing
    local test_cache="$TEST_TEMP_DIR/cache"
    mkdir -p "$test_cache"

    # Create a file owned by current user (simulating no root-owned files)
    touch "$test_cache/test-file"

    # Override fix_cache_permissions to use our test dir by redefining it
    # Since the function hardcodes /cache, we test the early exit path
    # (no /cache dir) and the message paths separately
    if [ ! -d "/cache" ]; then
        # No /cache dir means function returns 0 immediately
        fix_cache_permissions
        assert_equals "0" "$?" "Returns 0 silently when /cache does not exist"
    else
        skip_test "/cache exists on this system"
    fi
}

# ============================================================================
# Test: fix_cache_permissions message when no sudo available
# ============================================================================
test_fix_cache_no_sudo_message() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"

    # If /cache exists and has misowned files but user can't sudo, we expect
    # a warning message. We test the output strings exist in the script.
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh")

    assert_contains "$script_content" "no root access or sudo" \
        "Script contains no-sudo warning message"
    assert_contains "$script_content" "ENABLE_PASSWORDLESS_SUDO" \
        "Script references ENABLE_PASSWORDLESS_SUDO fix"
}

# ============================================================================
# Test: fix_cache_permissions message on chown success
# ============================================================================
test_fix_cache_success_message() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh")

    assert_contains "$script_content" "Cache directory ownership aligned" \
        "Script contains success message"
}

# ============================================================================
# Test: fix_cache_permissions message on chown failure
# ============================================================================
test_fix_cache_chown_fail_message() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh")

    assert_contains "$script_content" "Could not fix all cache permissions" \
        "Script contains chown failure warning"
}

# ============================================================================
# Test: prefers the reconcile-cache-owner wrapper (command-scoped sudo, #675)
# ============================================================================
test_fix_cache_prefers_wrapper() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh")

    assert_contains "$script_content" "reconcile-cache-owner" \
        "Script prefers the reconcile-cache-owner wrapper"
    assert_contains "$script_content" "command -v reconcile-cache-owner" \
        "Script guards the wrapper behind a command -v check with a direct-chown fallback"
}

# ============================================================================
# Test: Function is defined after sourcing
# ============================================================================
test_fix_cache_function_defined() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"
    assert_function_exists "fix_cache_permissions" "fix_cache_permissions function is defined"
}

# ============================================================================
# Predicate tests: these call _cache_needs_fix, the trigger predicate that
# fix_cache_permissions itself runs, sourced from the production lib. A change
# to the production `find` expression is therefore seen here directly.
#
# Helper: run the production predicate and echo its exit status (0 = a fix
# would be triggered, 1 = everything aligned).
# ============================================================================
cache_needs_fix_status() {
    # $1 = test cache root, $2 = target uid, $3 = target gid
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"
    local rc=0
    _cache_needs_fix "$1" "$2" "$3" || rc=$?
    echo "$rc"
}

# ============================================================================
# Test: predicate is silent when all files already match runtime UID/GID
# ============================================================================
test_predicate_aligned_cache() {
    local cache="$TEST_TEMP_DIR/aligned-cache"
    mkdir -p "$cache/sub"
    touch "$cache/userfile" "$cache/sub/nested"

    local uid gid
    uid=$(id -u)
    gid=$(id -g)

    assert_equals "1" "$(cache_needs_fix_status "$cache" "$uid" "$gid")" \
        "Predicate is silent on aligned cache"
    # Positive control on the SAME fixture: status 1 also means "find saw
    # nothing" (missing root, find error), so prove find reached the entries.
    assert_equals "0" "$(cache_needs_fix_status "$cache" "$((uid + 12345))" "$gid")" \
        "Same fixture triggers under a foreign UID (find reached the entries)"
}

# ============================================================================
# Test: predicate triggers when cache contains a file with a foreign UID
# (this is the regression test for the Zed/VS Code USER_UID divergence bug —
# previously the predicate only checked for root-owned files and silently
# skipped UID-1000-vs-501 mismatches.)
# ============================================================================
test_predicate_triggers_on_foreign_uid() {
    local cache="$TEST_TEMP_DIR/foreign-cache"
    mkdir -p "$cache"
    touch "$cache/userfile"

    local uid gid foreign_uid
    uid=$(id -u)
    gid=$(id -g)
    # Pick a UID we definitely don't own. The predicate is purely numeric so
    # we don't need to actually chown — we simulate the divergence by passing
    # a target UID that doesn't match any file in the cache.
    foreign_uid=$((uid + 12345))

    assert_equals "0" "$(cache_needs_fix_status "$cache" "$foreign_uid" "$gid")" \
        "Predicate triggers when target UID differs from file UIDs"
}

# ============================================================================
# Test: predicate triggers when only the GID is misaligned
# ============================================================================
test_predicate_triggers_on_foreign_gid() {
    local cache="$TEST_TEMP_DIR/foreign-gid-cache"
    mkdir -p "$cache"
    touch "$cache/userfile"

    local uid gid foreign_gid
    uid=$(id -u)
    gid=$(id -g)
    foreign_gid=$((gid + 54321))

    assert_equals "0" "$(cache_needs_fix_status "$cache" "$uid" "$foreign_gid")" \
        "Predicate triggers when target GID differs from file GIDs"
}

# ============================================================================
# Test: predicate descends — the ONLY divergent entry is a nested file. The
# foreign UID/GID tests diverge at the root, so a predicate that stopped at
# depth 0 would still pass them. Without root we can only re-own a file to one
# of our own supplementary groups, so skip when there is none.
# ============================================================================
test_predicate_triggers_on_nested_divergence() {
    local uid gid other_gid=""
    uid=$(id -u)
    gid=$(id -g)
    local g
    for g in $(id -G); do
        if [ "$g" != "$gid" ]; then
            other_gid="$g"
            break
        fi
    done
    if [ -z "$other_gid" ]; then
        skip_test "no supplementary group to re-own a nested file without root"
        return 0
    fi

    local cache="$TEST_TEMP_DIR/nested-divergence-cache"
    mkdir -p "$cache/sub/deeper"
    touch "$cache/top" "$cache/sub/deeper/nested"
    chgrp "$other_gid" "$cache/sub/deeper/nested"

    assert_equals "0" "$(cache_needs_fix_status "$cache" "$uid" "$gid")" \
        "Predicate triggers when only a nested file diverges"
    # Control: re-align the nested file and the same tree must read aligned,
    # so the trigger above came from the nested file and not from the root
    # inheriting a foreign group (setgid TEST_TEMP_DIR, default ACLs).
    chgrp "$gid" "$cache/sub/deeper/nested"
    assert_equals "1" "$(cache_needs_fix_status "$cache" "$uid" "$gid")" \
        "Same tree is aligned once the nested file is re-owned"
}

# ============================================================================
# Test: scoped sudo (#996) — the reconcile runs through the wrapper instead of
# bailing on a `sudo -n true` probe. Stubs: `id` reports a target UID/GID that
# differs from the real /cache owner (forcing the fix branch), `sudo`
# implements the scoped allowlist (wrapper allowed, `true` refused) and logs
# what it ran, and the wrapper itself is a no-op. Fails on the pre-#996 probe.
# ============================================================================
test_cache_scoped_sudo_runs_wrapper() {
    if [ ! -d /cache ]; then
        skip_test "/cache not present on this host"
        return 0
    fi
    local stub_dir="$TEST_TEMP_DIR/scoped-stubs"
    command mkdir -p "$stub_dir"
    command cat >"$stub_dir/id" <<'EOF'
#!/bin/bash
case "${1:-}" in
    -u) echo 424242 ;;
    -g) echo 424243 ;;
    *) exec /usr/bin/id "$@" ;;
esac
EOF
    command cat >"$stub_dir/sudo" <<EOF
#!/bin/bash
[ "\${1:-}" = "-n" ] && shift
list=false
[ "\${1:-}" = "-l" ] && { list=true; shift; }
case "\$1" in
    reconcile-cache-owner) ;;
    *) exit 1 ;;
esac
\$list || printf '%s\n' "\$*" >>"$stub_dir/ran"
exit 0
EOF
    command printf '#!/bin/bash\nexit 0\n' >"$stub_dir/reconcile-cache-owner"
    command chmod +x "$stub_dir"/*

    local output
    output=$(
        export BASH_ENV=""
        export PATH="$stub_dir:$PATH"
        RUNNING_AS_ROOT=false
        USERNAME=testuser
        run_privileged() { sudo "$@"; }
        unset _PRIVILEGED_LOADED
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/runtime/lib/privileged.sh"
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"
        fix_cache_permissions 2>&1
    )

    assert_not_contains "$output" "no root access or sudo" \
        "Scoped sudo is recognized (no warn-and-skip)"
    local ran
    ran=$(command cat "$stub_dir/ran" 2>/dev/null || true)
    assert_contains "$ran" "reconcile-cache-owner 424242 424243" \
        "The reconcile wrapper ran via sudo with the target uid/gid"
}

# Run tests
run_test test_fix_cache_no_cache_dir "Returns 0 when /cache does not exist"
run_test test_fix_cache_output_no_root "Handles missing /cache silently"
run_test test_fix_cache_no_sudo_message "Contains no-sudo warning message"
run_test test_fix_cache_success_message "Contains success message"
run_test test_fix_cache_chown_fail_message "Contains chown failure warning"
run_test test_fix_cache_prefers_wrapper "Prefers reconcile-cache-owner wrapper"
run_test test_fix_cache_function_defined "Function is defined after sourcing"
run_test test_predicate_aligned_cache "Predicate silent on aligned cache"
run_test test_predicate_triggers_on_foreign_uid "Predicate triggers on foreign UID (regression)"
run_test test_predicate_triggers_on_foreign_gid "Predicate triggers on foreign GID"
run_test test_predicate_triggers_on_nested_divergence "Predicate triggers on nested-only divergence"
run_test test_cache_scoped_sudo_runs_wrapper "Scoped sudo runs the reconcile-cache-owner wrapper (#996)"

# Generate test report
generate_report
