#!/usr/bin/env bash
# Unit tests: every committed GPG keyring directory is readable by gpg
#
# gpg can list most of a damaged keyring's keys before exiting non-zero, and
# lib/base/gpg-verify.sh gates Tier 1 signature verification on that exit
# status. A keyring that fails here silently drops installs to the checksum
# tiers, so the build stays green while signature verification is lost (#1410).

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Committed GPG Keyrings Readable"

# Shared gpg fixtures: require_gpg (#1456)
# shellcheck source=tests/lib/gpg-keyring-fixtures.sh
source "$PROJECT_ROOT/tests/lib/gpg-keyring-fixtures.sh"

GPG_KEYS_ROOT="$PROJECT_ROOT/lib/gpg-keys"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-gpg-keyrings-readable-$unique_id"
    command mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# check_keyring <keyring_dir> <scratch_dir>
# Copy the keyring to a private scratch GNUPGHOME (gpg must not write into the
# repo) and list its keys. Returns 0 only when gpg exits 0 AND lists >=1 key.
check_keyring() {
    local src="$1"
    local home="$2"
    local output count
    command mkdir -p "$home"
    command cp "$src"/* "$home"/
    command chmod 700 "$home"
    command chmod 600 "$home"/*
    output=$(GNUPGHOME="$home" gpg --batch --list-keys 2>&1) || return 1
    count=$(printf '%s\n' "$output" | command grep -c '^pub' || true)
    [ "${count:-0}" -ge 1 ]
}

# Test: every lib/gpg-keys/*/keyring directory is readable
test_committed_keyrings_readable() {
    require_gpg || return 0

    local keyrings=()
    local dir
    for dir in "$GPG_KEYS_ROOT"/*/keyring; do
        [ -d "$dir" ] && keyrings+=("$dir")
    done
    # Guard against the glob matching nothing and the loop passing vacuously
    assert_not_equals "0" "${#keyrings[@]}" "expected at least one committed keyring directory"

    local i=0
    for dir in "${keyrings[@]}"; do
        i=$((i + 1))
        if check_keyring "$dir" "$TEST_TEMP_DIR/home-$i"; then
            assert_true true "${dir#"$PROJECT_ROOT"/} is readable"
        else
            assert_true false "${dir#"$PROJECT_ROOT"/} is not readable by gpg (rc!=0 or no keys)"
        fi
    done
}

# Test: the check rejects a keyring with one byte appended — the exact damage
# auto-patch's trailing-newline fixer did (#1410) — so a pass above means
# something rather than reflecting a check that cannot fail
test_check_rejects_appended_byte() {
    require_gpg || return 0

    local corrupt="$TEST_TEMP_DIR/corrupt"
    command mkdir -p "$corrupt"
    command cp "$GPG_KEYS_ROOT"/nodejs/keyring/* "$corrupt"/
    printf '\n' >>"$corrupt/pubring.kbx"

    if check_keyring "$corrupt" "$TEST_TEMP_DIR/home-corrupt"; then
        assert_true false "check_keyring accepted a keyring with a trailing byte appended"
    else
        assert_true true "check_keyring rejects a keyring with a trailing byte appended"
    fi
}

run_test_with_setup test_committed_keyrings_readable "Every committed keyring is readable by gpg"
run_test_with_setup test_check_rejects_appended_byte "Readability check rejects a byte-appended keyring"

# Generate test report
generate_report
