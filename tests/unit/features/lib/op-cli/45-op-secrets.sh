#!/usr/bin/env bash
# Unit tests for lib/features/lib/op-cli/45-op-secrets.sh
# Tests error paths, graceful failure behaviour, and the persistent secret cache.

set -euo pipefail

# Source test framework (4 levels up)
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"
init_test_framework
test_suite "45-op-secrets Error Path + Cache Tests"

# Path to script under test + companion feature installer (for cache-dir creation)
SOURCE_FILE="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
FEATURE_FILE="$PROJECT_ROOT/lib/features/op-cli.sh"

# ============================================================================
# Custom setup/teardown: preserves the framework's TEST_TEMP_DIR convention
# but also restores env and PATH modified by the behavioural tests.
# ============================================================================

setup() {
    TEST_TEMP_DIR=$(mktemp -d -t "container-test-XXXXXX")
    export TEST_TEMP_DIR
}

teardown() {
    # Restore env any behavioural test may have set
    unset OP_GITHUB_TOKEN_REF OP_GIT_USER_NAME_REF OP_SERVICE_ACCOUNT_TOKEN \
          OP_SECRET_CACHE_DIR OP_SECRET_CACHE_FALLBACK_DIR OP_SECRET_CACHE_TTL \
          OP_SECRET_CACHE_MAX_CONCURRENT OP_READ_MAX_ATTEMPTS OP_READ_RETRY_DELAY \
          ENV_SECRETS_FILE MOCK_BIN_DIR MOCK_COUNTER TEST_CACHE_DIR \
          TEST_FALLBACK_DIR TEST_SCRIPT TEST_EMPTY_ENV TEST_STDERR
    if [ -n "${_ORIG_PATH+x}" ]; then
        PATH="$_ORIG_PATH"
        unset _ORIG_PATH
    fi
    if [ -n "${_ORIG_HOME+x}" ]; then
        HOME="$_ORIG_HOME"
        unset _ORIG_HOME
    fi
    # Clean up the /dev/shm test dirs (teardown of TEST_TEMP_DIR doesn't reach them)
    if [ -n "${_TEST_SHM_DIRS:-}" ]; then
        local _d
        for _d in $_TEST_SHM_DIRS; do
            [ -d "$_d" ] && command rm -rf "$_d"
        done
        unset _TEST_SHM_DIRS
    fi
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR
}

# Prepare a sandboxed env for behavioural tests. Writes a mock `op` binary to
# $MOCK_BIN_DIR and a /dev/shm-patched copy of the script under test to
# $TEST_SCRIPT, so running the script never pollutes the host's /dev/shm
# cache file. Each mock `op` invocation appends one line to $MOCK_COUNTER.
#
# Cache dirs are placed on /dev/shm (guaranteed tmpfs) so the script's
# tmpfs-required check passes and the primary cache path is exercised.
# Fallback dir is also explicitly overridden so tests don't collide on the
# default /dev/shm/op-secrets-persistent location.
_prepare_mock_env() {
    local suffix="$$-$RANDOM"
    export TEST_CACHE_DIR="/dev/shm/op-test-cache-${suffix}"
    export TEST_FALLBACK_DIR="/dev/shm/op-test-fallback-${suffix}"
    export MOCK_BIN_DIR="$TEST_TEMP_DIR/bin"
    export MOCK_COUNTER="$TEST_TEMP_DIR/op-calls"
    export TEST_SCRIPT="$TEST_TEMP_DIR/45-op-secrets.sh"
    export TEST_EMPTY_ENV="$TEST_TEMP_DIR/empty.env.secrets"
    export TEST_STDERR="$TEST_TEMP_DIR/stderr"
    mkdir -p "$TEST_CACHE_DIR" "$MOCK_BIN_DIR"
    : > "$MOCK_COUNTER"
    : > "$TEST_EMPTY_ENV"
    # Register /dev/shm dirs for teardown cleanup
    export _TEST_SHM_DIRS="$TEST_CACHE_DIR $TEST_FALLBACK_DIR /dev/shm/op-secrets-persistent"

    # Mock op records each invocation then emits a deterministic value.
    # Note the unquoted heredoc: ${MOCK_COUNTER} expands now; \$* / \$1 / \$2
    # stay literal for evaluation inside the mock.
    command cat > "$MOCK_BIN_DIR/op" <<EOF
#!/bin/bash
echo "\$*" >> "${MOCK_COUNTER}"
if [ "\$1" = "read" ]; then
    printf 'mock-value:%s' "\$2"
    exit 0
fi
exit 1
EOF
    chmod +x "$MOCK_BIN_DIR/op"

    # Patched copy of the script: redirect all /dev/shm writes into TEST_TEMP_DIR
    # so host state (notably /dev/shm/op-secrets-cache) is never overwritten.
    command sed \
        -e "s|/dev/shm/op-fetch|${TEST_TEMP_DIR}/op-fetch|g" \
        -e "s|/dev/shm/op-stderr|${TEST_TEMP_DIR}/op-stderr|g" \
        -e "s|/dev/shm/op-secrets-cache|${TEST_TEMP_DIR}/op-secrets-cache|g" \
        -e "s|/dev/shm/\${_file_name}|${TEST_TEMP_DIR}/\${_file_name}|g" \
        "$SOURCE_FILE" > "$TEST_SCRIPT"
    chmod +x "$TEST_SCRIPT"

    export _ORIG_PATH="$PATH"
    export _ORIG_HOME="$HOME"
    PATH="$MOCK_BIN_DIR:$PATH"
    HOME="$TEST_TEMP_DIR"
    export OP_SERVICE_ACCOUNT_TOKEN="mock-token"
    export OP_SECRET_CACHE_DIR="$TEST_CACHE_DIR"
    export OP_SECRET_CACHE_FALLBACK_DIR="$TEST_FALLBACK_DIR"
    export ENV_SECRETS_FILE="$TEST_EMPTY_ENV"
}

# Run the script under test in a sandboxed env. We use `env -i` with an
# explicit whitelist so the script doesn't inherit the real container's
# OP_*_REF vars, GITHUB_TOKEN, etc. — otherwise the script's
# "target already set → skip" branch makes the mock `op` unreachable.
_run_script_isolated() {
    env -i \
        PATH="${MOCK_BIN_DIR}:/usr/bin:/bin:/usr/local/bin" \
        HOME="${TEST_TEMP_DIR}" \
        OP_SERVICE_ACCOUNT_TOKEN="${OP_SERVICE_ACCOUNT_TOKEN:-}" \
        OP_GITHUB_TOKEN_REF="${OP_GITHUB_TOKEN_REF:-}" \
        OP_GIT_USER_NAME_REF="${OP_GIT_USER_NAME_REF:-}" \
        OP_SECRET_CACHE_DIR="${OP_SECRET_CACHE_DIR:-}" \
        OP_SECRET_CACHE_FALLBACK_DIR="${OP_SECRET_CACHE_FALLBACK_DIR:-}" \
        OP_SECRET_CACHE_TTL="${OP_SECRET_CACHE_TTL:-}" \
        OP_SECRET_CACHE_MAX_CONCURRENT="${OP_SECRET_CACHE_MAX_CONCURRENT:-}" \
        OP_READ_MAX_ATTEMPTS="${OP_READ_MAX_ATTEMPTS:-}" \
        OP_READ_RETRY_DELAY="${OP_READ_RETRY_DELAY:-}" \
        ENV_SECRETS_FILE="${ENV_SECRETS_FILE:-}" \
        bash "$TEST_SCRIPT"
}

# Count mock op invocations (one line per call).
_mock_call_count() {
    command wc -l < "$MOCK_COUNTER" 2>/dev/null | command tr -d ' '
}

# sha256 hex of a string (matches the script's key derivation).
_ref_hash() {
    printf '%s' "$1" | sha256sum | command awk '{print $1}'
}

# ============================================================================
# Script Structure Tests
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] \
        && assert_true 0 "45-op-secrets.sh is executable" \
        || assert_true 1 "45-op-secrets.sh should be executable"
}

test_uses_set_plus_e() {
    # This script intentionally uses set +e for graceful failure
    assert_file_contains "$SOURCE_FILE" "set +e" \
        "45-op-secrets.sh uses set +e (graceful failure by design)"
}

# ============================================================================
# Error Path 1: No op binary
# ============================================================================

test_op_binary_guard() {
    # Must check for op binary and exit 0 if not found
    assert_file_contains "$SOURCE_FILE" "command -v op" \
        "45-op-secrets.sh checks for op binary via command -v"
}

test_op_binary_guard_exits_zero() {
    # The guard should exit 0 (not fail) when op is missing
    if command grep -q 'command -v op.*exit 0' "$SOURCE_FILE"; then
        pass_test "op binary guard exits 0 when op not found"
    else
        fail_test "op binary guard should exit 0 when op not found"
    fi
}

# ============================================================================
# Error Path 2: No service account token
# ============================================================================

test_service_account_token_guard() {
    # Must check OP_SERVICE_ACCOUNT_TOKEN and exit 0 if empty
    assert_file_contains "$SOURCE_FILE" "OP_SERVICE_ACCOUNT_TOKEN" \
        "45-op-secrets.sh checks OP_SERVICE_ACCOUNT_TOKEN"
}

test_service_account_token_exits_zero() {
    # The guard should exit 0 (not fail) when token is empty
    if command grep -q 'OP_SERVICE_ACCOUNT_TOKEN.*exit 0' "$SOURCE_FILE"; then
        pass_test "Service account token guard exits 0 when token empty"
    else
        fail_test "Service account token guard should exit 0 when token empty"
    fi
}

# ============================================================================
# Error Path 3: op read failure handled gracefully
# ============================================================================

test_op_read_failure_handled() {
    # op read failures must be handled gracefully — the backoff helper wraps
    # `op read` with captured stderr and returns non-zero on unrecoverable
    # failure (callers branch on the return code or empty output).
    if command grep -q '_op_read_with_backoff' "$SOURCE_FILE" \
       && command grep -q 'op read .* 2>' "$SOURCE_FILE"; then
        pass_test "op read failure handled via backoff helper"
    else
        fail_test "op read failure should be handled via a backoff helper"
    fi
}

test_op_read_stderr_captured_or_suppressed() {
    # Stderr must not leak to the user's terminal during non-interactive startup.
    # Either redirected to /dev/null or captured to a tmpfile for throttle detection.
    if command grep -qE 'op read .*2>"?\$stderr_file' "$SOURCE_FILE" \
       || command grep -qE 'op read .*2>/dev/null' "$SOURCE_FILE"; then
        pass_test "op read stderr handled (captured or suppressed)"
    else
        fail_test "op read stderr should be captured or suppressed"
    fi
}

test_file_ref_op_read_failure_handled() {
    # Both REF and FILE_REF call sites route through _op_read_cached, so the
    # same failure handling applies. Expect at least three _fetch_to_file
    # invocations (REF loop, FILE_REF loop, git-identity first+last).
    local count
    count=$(command grep -c '_launch_fetch _fetch_to_file' "$SOURCE_FILE" || true)
    [ "$count" -ge 3 ] \
        && assert_true 0 "All three fetch call sites route through cached helper (found $count)" \
        || assert_true 1 "Expected at least 3 cached fetch call sites, found $count"
}

# ============================================================================
# Security: xtrace protection
# ============================================================================

test_xtrace_disabled_during_processing() {
    assert_file_contains "$SOURCE_FILE" "set +x" \
        "Xtrace disabled during secret processing"
}

test_xtrace_restored_after_processing() {
    # Must restore xtrace state via boolean flag (no eval)
    assert_file_contains "$SOURCE_FILE" '_xtrace_was_on=false' \
        "Xtrace state captured via boolean flag"
    assert_file_contains "$SOURCE_FILE" 'if \[ "\$_xtrace_was_on" = true \]; then set -x; fi' \
        "Xtrace state restored via boolean flag"
}

# ============================================================================
# Interactive-shell cache: atomic write (/dev/shm/op-secrets-cache, unchanged)
# ============================================================================

test_cache_atomic_write() {
    # Cache must be written atomically via .tmp.$$ + mv
    if command grep -Fq '.tmp.$$' "$SOURCE_FILE"; then
        pass_test "Cache uses .tmp.\$\$ for atomic write"
    else
        fail_test "Cache should use .tmp.\$\$ for atomic write"
    fi
    if command grep -q 'mv .*_cache_tmp.*_cache_file' "$SOURCE_FILE"; then
        pass_test "Cache uses mv for atomic rename"
    else
        fail_test "Cache should use mv for atomic rename"
    fi
}

# ============================================================================
# Persistent cache (issue #375) — structural tests
# ============================================================================

test_persistent_cache_helper_defined() {
    assert_file_contains "$SOURCE_FILE" '_op_read_cached()' \
        "Defines _op_read_cached helper"
}

test_backoff_helper_defined() {
    assert_file_contains "$SOURCE_FILE" '_op_read_with_backoff()' \
        "Defines _op_read_with_backoff helper"
}

test_semaphore_helper_defined() {
    assert_file_contains "$SOURCE_FILE" '_launch_fetch()' \
        "Defines _launch_fetch helper"
    assert_file_contains "$SOURCE_FILE" 'wait -n' \
        "_launch_fetch uses 'wait -n' for job draining"
}

test_persistent_cache_dir_path() {
    assert_file_contains "$SOURCE_FILE" '/cache/1password/secrets' \
        "Persistent cache defaults to /cache/1password/secrets"
}

test_persistent_cache_uses_sha256() {
    assert_file_contains "$SOURCE_FILE" 'sha256sum' \
        "Cache key derived via sha256sum"
}

test_persistent_cache_atomic_write_new() {
    # New cache uses mktemp + chmod 600 + mv in the cache dir
    if command grep -q 'mktemp.*_op_secret_cache_dir' "$SOURCE_FILE"; then
        pass_test "Persistent cache uses mktemp inside cache dir"
    else
        fail_test "Persistent cache should use mktemp inside cache dir"
    fi
    if command grep -q 'mv -f.*cache_file' "$SOURCE_FILE"; then
        pass_test "Persistent cache uses mv -f for atomic rename"
    else
        fail_test "Persistent cache should use mv -f for atomic rename"
    fi
}

test_persistent_cache_ttl_env_var() {
    assert_file_contains "$SOURCE_FILE" 'OP_SECRET_CACHE_TTL:-1800' \
        "TTL configurable via OP_SECRET_CACHE_TTL (default 1800s / 30 min)"
}

test_persistent_cache_ttl_zero_disables() {
    # The bypass branch must trigger when TTL <= 0
    if command grep -qE '\$ttl["}]* -le 0' "$SOURCE_FILE"; then
        pass_test "TTL <= 0 bypasses the cache"
    else
        fail_test "TTL <= 0 should bypass the cache"
    fi
}

test_persistent_cache_dir_mode_0700() {
    # The script creates the cache dir mode 0700 at runtime (fallback).
    if command grep -qE 'chmod 700 "\$_op_secret_cache_dir"' "$SOURCE_FILE"; then
        pass_test "Runtime cache dir chmod 700"
    else
        fail_test "Runtime cache dir should be chmod 700"
    fi
    # And the feature installer creates it mode 0700 at build time.
    if command grep -qE "install -d -m 0700 .*/cache/1password/secrets" "$FEATURE_FILE" \
       || command grep -qE "OP_SECRET_CACHE_DIR.*0700|0700.*OP_SECRET_CACHE_DIR" "$FEATURE_FILE"; then
        pass_test "Build-time cache dir installed mode 0700"
    else
        fail_test "op-cli.sh should install /cache/1password/secrets mode 0700"
    fi
}

test_persistent_cache_file_mode_0600() {
    assert_file_contains "$SOURCE_FILE" "chmod 600 \"\$tmp\"" \
        "Cache files written mode 0600"
}

test_throttle_detection_patterns() {
    # Stderr grep covers the common 1Password throttle signatures
    assert_file_contains "$SOURCE_FILE" "rate.?limit" \
        "Throttle detection includes 'rate limit' pattern"
    assert_file_contains "$SOURCE_FILE" "429" \
        "Throttle detection includes '429' pattern"
    assert_file_contains "$SOURCE_FILE" "throttl" \
        "Throttle detection includes 'throttl' pattern"
}

test_concurrency_env_var() {
    assert_file_contains "$SOURCE_FILE" 'OP_SECRET_CACHE_MAX_CONCURRENT:-4' \
        "Concurrency configurable via OP_SECRET_CACHE_MAX_CONCURRENT (default 4)"
}

test_retry_env_vars() {
    assert_file_contains "$SOURCE_FILE" 'OP_READ_MAX_ATTEMPTS:-3' \
        "Retry count configurable via OP_READ_MAX_ATTEMPTS (default 3)"
    assert_file_contains "$SOURCE_FILE" 'OP_READ_RETRY_DELAY:-1' \
        "Retry delay configurable via OP_READ_RETRY_DELAY (default 1s)"
}

test_tmpfs_check_enforced() {
    # Primary cache must be verified as tmpfs-backed (or ramfs) before use,
    # ensuring resolved secrets never land on disk.
    # shfmt may add spaces around | in case patterns: (tmpfs|ramfs) vs (tmpfs | ramfs)
    if command grep -qE 'stat -f -c .%T' "$SOURCE_FILE" \
       && command grep -qE 'tmpfs[[:space:]]*\|[[:space:]]*ramfs|tmpfs\).*ramfs\)' "$SOURCE_FILE"; then
        pass_test "Primary cache gated on tmpfs/ramfs filesystem type"
    else
        fail_test "Primary cache must be verified as tmpfs-backed via stat -f"
    fi
}

test_fallback_env_var() {
    assert_file_contains "$SOURCE_FILE" 'OP_SECRET_CACHE_FALLBACK_DIR' \
        "Fallback cache dir configurable via OP_SECRET_CACHE_FALLBACK_DIR"
    assert_file_contains "$SOURCE_FILE" '/dev/shm/op-secrets-persistent' \
        "Fallback defaults to /dev/shm/op-secrets-persistent"
}

test_fallback_warning_present() {
    # Degraded-mode warning must explain the downgrade and point to docs.
    assert_file_contains "$SOURCE_FILE" 'not tmpfs-backed' \
        "Degraded-mode warning mentions the tmpfs requirement"
    assert_file_contains "$SOURCE_FILE" 'docs/claude-code/secrets-and-setup.md' \
        "Warning points to the secrets-and-setup docs for the compose snippet"
}

# ============================================================================
# Persistent cache — behavioural tests (mock `op` binary)
# ============================================================================

test_persistent_cache_miss_populates() {
    _prepare_mock_env
    export OP_GITHUB_TOKEN_REF="op://test/github/token"

    _run_script_isolated >/dev/null 2>&1 || true

    local calls hash mode
    calls=$(_mock_call_count)
    if [ "$calls" -ge 1 ]; then
        pass_test "Cold run calls op read ($calls calls)"
    else
        fail_test "Cold run should call op read, got $calls calls"
        return
    fi

    hash=$(_ref_hash "op://test/github/token")
    if [ -f "$TEST_CACHE_DIR/$hash" ]; then
        pass_test "Cache file created at SHA256-keyed path"
    else
        fail_test "Cache file not created at $TEST_CACHE_DIR/$hash"
        return
    fi

    if command grep -q 'mock-value:op://test/github/token' "$TEST_CACHE_DIR/$hash" 2>/dev/null; then
        pass_test "Cache file contains resolved secret"
    else
        fail_test "Cache file content did not match mock output"
    fi

    mode=$(command stat -c '%a' "$TEST_CACHE_DIR/$hash" 2>/dev/null)
    if [ "$mode" = "600" ]; then
        pass_test "Cache file mode is 0600"
    else
        fail_test "Cache file mode should be 0600, got $mode"
    fi
}

test_persistent_cache_hit_skips_op() {
    _prepare_mock_env
    export OP_GITHUB_TOKEN_REF="op://test/github/token"

    # Pre-populate a fresh cache file
    local hash
    hash=$(_ref_hash "op://test/github/token")
    printf 'cached-secret-value' > "$TEST_CACHE_DIR/$hash"
    chmod 600 "$TEST_CACHE_DIR/$hash"

    _run_script_isolated >/dev/null 2>&1 || true

    local calls
    calls=$(_mock_call_count)
    if [ "$calls" -eq 0 ]; then
        pass_test "Fresh cache hit skipped op read entirely"
    else
        fail_test "Fresh cache hit should skip op read, got $calls calls"
    fi
}

test_persistent_cache_stale_refetches() {
    _prepare_mock_env
    export OP_GITHUB_TOKEN_REF="op://test/github/token"
    export OP_SECRET_CACHE_TTL=60

    local hash
    hash=$(_ref_hash "op://test/github/token")
    printf 'stale-cached-value' > "$TEST_CACHE_DIR/$hash"
    chmod 600 "$TEST_CACHE_DIR/$hash"
    command touch -d "1 hour ago" "$TEST_CACHE_DIR/$hash"

    _run_script_isolated >/dev/null 2>&1 || true

    local calls
    calls=$(_mock_call_count)
    if [ "$calls" -ge 1 ]; then
        pass_test "Stale cache triggered refetch ($calls calls)"
    else
        fail_test "Stale cache should trigger refetch, got $calls calls"
        return
    fi

    if command grep -q 'mock-value:op://test/github/token' "$TEST_CACHE_DIR/$hash" 2>/dev/null; then
        pass_test "Cache updated with fresh value"
    else
        fail_test "Cache should be overwritten with fresh mock value"
    fi
}

test_non_tmpfs_primary_falls_back() {
    _prepare_mock_env
    export OP_GITHUB_TOKEN_REF="op://test/github/token"
    # Force primary to a disk-backed path so the tmpfs check fails
    export OP_SECRET_CACHE_DIR="$TEST_TEMP_DIR/disk-primary"

    local exit_code=0
    _run_script_isolated >/dev/null 2>"$TEST_STDERR" || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        pass_test "Script exits 0 with disk-backed primary"
    else
        fail_test "Script should exit 0 with disk-backed primary (got $exit_code)"
    fi

    local hash
    hash=$(_ref_hash "op://test/github/token")

    # Primary (disk) must NOT have been used as the cache
    if [ ! -f "$TEST_TEMP_DIR/disk-primary/$hash" ]; then
        pass_test "Disk primary never holds resolved secrets"
    else
        fail_test "Resolved secret leaked to disk-backed primary cache"
    fi

    # Fallback (tmpfs) must have been used
    if [ -f "$TEST_FALLBACK_DIR/$hash" ]; then
        pass_test "Fallback tmpfs cache populated"
    else
        fail_test "Fallback tmpfs cache should be populated at $TEST_FALLBACK_DIR/$hash"
    fi

    # Warning must have been emitted on stderr explaining the degradation
    if command grep -q 'not tmpfs-backed' "$TEST_STDERR" 2>/dev/null \
       && command grep -q 'downgraded' "$TEST_STDERR" 2>/dev/null; then
        pass_test "Stderr warning explains the tmpfs downgrade"
    else
        fail_test "Expected tmpfs-downgrade warning on stderr; got: $(command cat "$TEST_STDERR" 2>/dev/null | command head -5)"
    fi
}

test_no_cache_graceful() {
    _prepare_mock_env
    export OP_GITHUB_TOKEN_REF="op://test/github/token"
    # Both primary and fallback unavailable (/proc/* paths cannot be created)
    export OP_SECRET_CACHE_DIR="/proc/cannot-create-primary"
    export OP_SECRET_CACHE_FALLBACK_DIR="/proc/cannot-create-fallback"

    local exit_code=0
    _run_script_isolated >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        pass_test "Script exits 0 when no cache available"
    else
        fail_test "Script should exit 0 with no cache (got $exit_code)"
    fi

    local calls
    calls=$(_mock_call_count)
    if [ "$calls" -ge 1 ]; then
        pass_test "Uncached mode still calls op read ($calls calls)"
    else
        fail_test "Uncached mode should still call op read, got $calls"
    fi
}

test_persistent_cache_ttl_zero_bypasses() {
    _prepare_mock_env
    export OP_GITHUB_TOKEN_REF="op://test/github/token"
    export OP_SECRET_CACHE_TTL=0

    # Pre-populate what would otherwise be a fresh hit
    local hash
    hash=$(_ref_hash "op://test/github/token")
    printf 'cached-value' > "$TEST_CACHE_DIR/$hash"
    chmod 600 "$TEST_CACHE_DIR/$hash"

    _run_script_isolated >/dev/null 2>&1 || true

    local calls
    calls=$(_mock_call_count)
    if [ "$calls" -ge 1 ]; then
        pass_test "TTL=0 bypasses cache ($calls calls)"
    else
        fail_test "TTL=0 should bypass cache and call op read, got $calls"
    fi
}

# ============================================================================
# Exit behaviour
# ============================================================================

test_exits_zero_on_completion() {
    # Script must end with exit 0
    local last_code_line
    last_code_line=$(command grep -n '^exit' "$SOURCE_FILE" | command tail -1)
    echo "$last_code_line" | command grep -q 'exit 0' \
        && assert_true 0 "Script ends with exit 0" \
        || assert_true 1 "Script should end with exit 0"
}

# ============================================================================
# Test runner
# ============================================================================

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_set_plus_e "Uses set +e (graceful failure by design)"
run_test test_op_binary_guard "Error path 1: checks for op binary"
run_test test_op_binary_guard_exits_zero "Error path 1: exits 0 when op not found"
run_test test_service_account_token_guard "Error path 2: checks OP_SERVICE_ACCOUNT_TOKEN"
run_test test_service_account_token_exits_zero "Error path 2: exits 0 when token empty"
run_test test_op_read_failure_handled "Error path 3: op read failure handled via backoff"
run_test test_op_read_stderr_captured_or_suppressed "Error path 3: op read stderr handled"
run_test test_file_ref_op_read_failure_handled "Error path 3: all call sites routed through cache"
run_test test_xtrace_disabled_during_processing "Xtrace disabled during secret processing"
run_test test_xtrace_restored_after_processing "Xtrace restored after processing"
run_test test_cache_atomic_write "/dev/shm cache written atomically (.tmp + mv)"
run_test test_persistent_cache_helper_defined "Persistent cache: _op_read_cached defined"
run_test test_backoff_helper_defined "Persistent cache: _op_read_with_backoff defined"
run_test test_semaphore_helper_defined "Persistent cache: _launch_fetch + wait -n defined"
run_test test_persistent_cache_dir_path "Persistent cache: dir is /cache/1password/secrets"
run_test test_persistent_cache_uses_sha256 "Persistent cache: sha256 key derivation"
run_test test_persistent_cache_atomic_write_new "Persistent cache: atomic mktemp + mv"
run_test test_persistent_cache_ttl_env_var "Persistent cache: OP_SECRET_CACHE_TTL env var"
run_test test_persistent_cache_ttl_zero_disables "Persistent cache: TTL<=0 disables"
run_test test_persistent_cache_dir_mode_0700 "Persistent cache: dir mode 0700 (runtime + build)"
run_test test_persistent_cache_file_mode_0600 "Persistent cache: files mode 0600"
run_test test_throttle_detection_patterns "Throttle detection: rate limit / 429 / throttle"
run_test test_concurrency_env_var "Concurrency cap: OP_SECRET_CACHE_MAX_CONCURRENT env var"
run_test test_retry_env_vars "Retry: OP_READ_MAX_ATTEMPTS + OP_READ_RETRY_DELAY env vars"
run_test test_tmpfs_check_enforced "Tmpfs: primary cache requires tmpfs/ramfs fs type"
run_test test_fallback_env_var "Tmpfs: OP_SECRET_CACHE_FALLBACK_DIR env var"
run_test test_fallback_warning_present "Tmpfs: degraded-mode warning text"
run_test test_persistent_cache_miss_populates "Behaviour: cache miss populates the cache"
run_test test_persistent_cache_hit_skips_op "Behaviour: fresh cache hit skips op read"
run_test test_persistent_cache_stale_refetches "Behaviour: stale cache triggers refetch"
run_test test_non_tmpfs_primary_falls_back "Behaviour: non-tmpfs primary falls back to /dev/shm"
run_test test_no_cache_graceful "Behaviour: all cache paths unavailable is graceful"
run_test test_persistent_cache_ttl_zero_bypasses "Behaviour: TTL=0 bypasses cache"
run_test test_exits_zero_on_completion "Exit 0 on completion"

generate_report
