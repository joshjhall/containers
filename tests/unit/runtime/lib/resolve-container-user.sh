#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/resolve-container-user.sh
#
# The ladder answers "who is the container user right now" for both the
# entrypoint (which drops privileges to it) and the fs-health cron leg (which
# re-execs as it, issue #800). Its whole reason to exist is that the runtime
# user is NOT the build-time one — editors remap it — so these tests pin the
# properties that make it remap-proof, above all that arm 2 matches on user
# SHAPE and not on a UID range.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Container User Resolution Tests"

RESOLVER_LIB="$PROJECT_ROOT/lib/runtime/lib/resolve-container-user.sh"

# Run resolve_container_user against a stubbed passwd database.
#
# `getent` is shimmed on PATH so the suite is hermetic — it must not depend on
# whichever users happen to exist on the host or in CI. BASH_ENV is cleared
# because /etc/bash_env rebuilds PATH on non-interactive bash, which would put
# the real getent ahead of the shim.
#
# Args: $1=passwd fixture contents, $2=CONTAINER_UID (optional)
# Prints the resolved user; exit status is the function's.
run_resolver() {
    local passwd_data="$1" container_uid="${2:-}"
    local stub_dir="$TEST_TEMP_DIR/stub-bin"
    command mkdir -p "$stub_dir"
    command printf '%s\n' "$passwd_data" >"$TEST_TEMP_DIR/passwd"

    command cat >"$stub_dir/getent" <<GETENT_EOF
#!/bin/bash
# getent passwd [uid] against the fixture.
[ "\${1:-}" = "passwd" ] || exit 2
if [ -n "\${2:-}" ]; then
    /usr/bin/awk -F: -v want="\$2" '\$3 == want { print; found=1 } END { exit !found }' "$TEST_TEMP_DIR/passwd"
else
    command cat "$TEST_TEMP_DIR/passwd"
fi
GETENT_EOF
    command chmod +x "$stub_dir/getent"

    (
        export BASH_ENV=""
        export PATH="$stub_dir:$PATH"
        if [ -n "$container_uid" ]; then
            export CONTAINER_UID="$container_uid"
        else
            unset CONTAINER_UID 2>/dev/null || true
        fi
        # shellcheck source=/dev/null
        source "$RESOLVER_LIB"
        resolve_container_user
    ) 2>/dev/null
}

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-resolve-container-user-$$"
    command mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR CONTAINER_UID 2>/dev/null || true
}

# A typical image passwd: root, some system accounts, one regular user.
PASSWD_STANDARD='root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
developer:x:1000:1000::/home/developer:/bin/bash'

# ============================================================================
# Test: function is defined after sourcing
# ============================================================================
test_resolver_function_defined() {
    # shellcheck source=/dev/null
    source "$RESOLVER_LIB"
    assert_function_exists "resolve_container_user" \
        "resolve_container_user function is defined"
}

# ============================================================================
# Test: CONTAINER_UID arm
# ============================================================================
test_resolves_from_container_uid() {
    local result
    result=$(run_resolver "$PASSWD_STANDARD" "1000")
    assert_equals "developer" "$result" \
        "CONTAINER_UID should resolve to that UID's username"
}

test_container_uid_wins_over_shape_match() {
    # An explicit override must beat the shape scan, even when both would
    # resolve — otherwise CONTAINER_UID would be advisory rather than an
    # override.
    local passwd_data result
    passwd_data='root:x:0:0:root:/root:/bin/bash
developer:x:1000:1000::/home/developer:/bin/bash
otheruser:x:1001:1001::/home/otheruser:/bin/bash'
    result=$(run_resolver "$passwd_data" "1001")
    assert_equals "otheruser" "$result" \
        "CONTAINER_UID should take precedence over the shape match"
}

test_container_uid_zero_does_not_resolve_root() {
    # CONTAINER_UID=0 must not hand back root. The cron leg's `su -l root` would
    # be a silent no-op — the privilege drop skipped, and the repair's writes
    # landing root-owned inside the user's workspace. Falls through to arm 2.
    local result
    result=$(run_resolver "$PASSWD_STANDARD" "0")
    assert_equals "developer" "$result" \
        "CONTAINER_UID=0 should fall through to the shape match, not resolve root"
}

test_container_uid_root_rejected_with_no_fallback() {
    # And with no regular user to fall back to, it must fail rather than
    # quietly returning root.
    local passwd_data status=0 output
    passwd_data='root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin'
    output=$(run_resolver "$passwd_data" "0") || status=$?

    assert_equals "1" "$status" \
        "CONTAINER_UID=0 with no regular user should fail, not return root"
    assert_empty "$output" \
        "CONTAINER_UID=0 with no regular user should print nothing"
}

test_container_uid_nologin_account_rejected() {
    # `su -l` into a nologin account just prints and exits, so accepting one
    # here would make the hourly repair silently never run — the same class of
    # no-op #800 removes, through a different door.
    local passwd_data result
    passwd_data='root:x:0:0:root:/root:/bin/bash
svc:x:998:998::/home/svc:/usr/sbin/nologin
developer:x:1000:1000::/home/developer:/bin/bash'
    result=$(run_resolver "$passwd_data" "998")
    assert_equals "developer" "$result" \
        "CONTAINER_UID naming a nologin account should fall through to the shape match"
}

test_falls_back_when_container_uid_unknown() {
    # A CONTAINER_UID with no passwd entry must fall through to the shape
    # match, not resolve to empty.
    local result
    result=$(run_resolver "$PASSWD_STANDARD" "4242")
    assert_equals "developer" "$result" \
        "An unmatched CONTAINER_UID should fall through to the shape match"
}

# ============================================================================
# Test: shape-match arm
# ============================================================================
test_resolves_by_shape_without_container_uid() {
    local result
    result=$(run_resolver "$PASSWD_STANDARD")
    assert_equals "developer" "$result" \
        "Should resolve the single regular login user by shape"
}

test_resolves_uid_below_1000() {
    # THE regression that matters: Zed remaps the container user to the host
    # UID (e.g. 501 on macOS), which lands inside Debian's system-UID range. A
    # UID-range filter would miss exactly the case this ladder exists for.
    local passwd_data result
    passwd_data='root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
developer:x:501:501::/home/developer:/bin/bash'
    result=$(run_resolver "$passwd_data")
    assert_equals "developer" "$result" \
        "A sub-1000 UID (Zed host-UID remap) should still resolve"
}

test_skips_nologin_accounts() {
    local passwd_data result
    passwd_data='root:x:0:0:root:/root:/bin/bash
svc:x:998:998::/home/svc:/usr/sbin/nologin
developer:x:1000:1000::/home/developer:/bin/bash'
    result=$(run_resolver "$passwd_data")
    assert_equals "developer" "$result" \
        "An account with a nologin shell should not be selected"
}

test_skips_false_shell_accounts() {
    # ubi-minimal ships no nologin, so hardened accounts there use
    # /usr/bin/false — the ladder must reject that shell too.
    local passwd_data result
    passwd_data='root:x:0:0:root:/root:/bin/bash
svc:x:998:998::/home/svc:/usr/bin/false
developer:x:1000:1000::/home/developer:/bin/bash'
    result=$(run_resolver "$passwd_data")
    assert_equals "developer" "$result" \
        "An account with a /usr/bin/false shell should not be selected"
}

test_skips_accounts_outside_home() {
    local passwd_data result
    passwd_data='root:x:0:0:root:/root:/bin/bash
sysuser:x:999:999::/var/lib/sysuser:/bin/bash
developer:x:1000:1000::/home/developer:/bin/bash'
    result=$(run_resolver "$passwd_data")
    assert_equals "developer" "$result" \
        "An account whose home is outside /home should not be selected"
}

test_never_selects_root() {
    # root has a real login shell; only the explicit name exclusion keeps the
    # ladder from "resolving" to it and defeating the privilege drop.
    local passwd_data result
    passwd_data='root:x:0:0:root:/home/root:/bin/bash
developer:x:1000:1000::/home/developer:/bin/bash'
    result=$(run_resolver "$passwd_data")
    assert_equals "developer" "$result" \
        "root should never be selected even with a /home directory"
}

# ============================================================================
# Test: unresolvable
# ============================================================================
test_returns_nonzero_when_unresolvable() {
    local passwd_data status=0 output
    passwd_data='root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin'
    output=$(run_resolver "$passwd_data") || status=$?

    assert_equals "1" "$status" \
        "Should return non-zero when no container user can be resolved"
    assert_empty "$output" \
        "Should print nothing when no container user can be resolved"
}

test_survives_set_e_caller() {
    # The `|| true` on each getent is load-bearing: without it a lookup miss
    # aborts a `set -e` caller inside the command substitution, before the
    # caller can report the failure itself (silent exit 2).
    local stub_dir="$TEST_TEMP_DIR/stub-bin-fail"
    command mkdir -p "$stub_dir"
    command cat >"$stub_dir/getent" <<'GETENT_FAIL_EOF'
#!/bin/bash
exit 2
GETENT_FAIL_EOF
    command chmod +x "$stub_dir/getent"

    local status=0
    (
        set -e
        export BASH_ENV=""
        export PATH="$stub_dir:$PATH"
        export CONTAINER_UID=1000
        # shellcheck source=/dev/null
        source "$RESOLVER_LIB"
        user=$(resolve_container_user) || true
        [ -z "$user" ]
        command echo "reached-the-guard"
    ) >/dev/null 2>&1 || status=$?

    assert_equals "0" "$status" \
        "A getent miss must not abort a set -e caller before its own guard"
}

# Run tests
#
# run_test_with_setup is a local helper (the framework's run_test does not
# bracket each case with setup/teardown), matching the sibling suite in
# tests/unit/runtime/workspace-fs-health.sh.
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

run_test test_resolver_function_defined "Function is defined after sourcing"
run_test_with_setup test_resolves_from_container_uid "Resolves from CONTAINER_UID"
run_test_with_setup test_container_uid_wins_over_shape_match "CONTAINER_UID wins over shape match"
run_test_with_setup test_container_uid_zero_does_not_resolve_root "CONTAINER_UID=0 does not resolve root"
run_test_with_setup test_container_uid_nologin_account_rejected "CONTAINER_UID naming a nologin account is rejected"
run_test_with_setup test_container_uid_root_rejected_with_no_fallback "CONTAINER_UID=0 fails when no regular user exists"
run_test_with_setup test_falls_back_when_container_uid_unknown "Unmatched CONTAINER_UID falls through"
run_test_with_setup test_resolves_by_shape_without_container_uid "Resolves by user shape"
run_test_with_setup test_resolves_uid_below_1000 "Sub-1000 UID resolves (Zed remap regression)"
run_test_with_setup test_skips_nologin_accounts "Skips nologin accounts"
run_test_with_setup test_skips_false_shell_accounts "Skips /usr/bin/false accounts"
run_test_with_setup test_skips_accounts_outside_home "Skips accounts outside /home"
run_test_with_setup test_never_selects_root "Never selects root"
run_test_with_setup test_returns_nonzero_when_unresolvable "Returns non-zero when unresolvable"
run_test_with_setup test_survives_set_e_caller "Survives a set -e caller on a getent miss"

# Generate test report
generate_report
