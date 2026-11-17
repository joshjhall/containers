#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/op-usable.sh (#1711)
#
# op_is_usable replaced the bare OP_SERVICE_ACCOUNT_TOKEN gates so an op
# authenticated by something else (an external credential provider) works.
# These tests pin the detection order, the "never hang, never prompt" bound on
# the whoami probe, the verdict caches, and the hand-off loader's refusals.
#
# Every probe runs in a child `bash` with BASH_ENV unset (it rebuilds PATH and
# would bypass the stub op) and every cache path pointed at scratch, so host
# /dev/shm state is neither read nor written.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "op-usable.sh (op_is_usable / credential_env_load) Tests"

# Overridable so a mutated scratch copy can be checked against this suite.
SOURCE_FILE="${OP_USABLE_SOURCE:-$PROJECT_ROOT/lib/runtime/lib/op-usable.sh}"

setup() {
    TEST_TEMP_DIR="$TEST_SCRATCH_BASE/op-usable-$$-$RANDOM"
    mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/cache"
    : >"$TEST_TEMP_DIR/op.calls"
}

teardown() {
    command rm -rf "${TEST_TEMP_DIR:-}" 2>/dev/null || true
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

# Stub op: records each call; `whoami` exits $1 (or sleeps forever on "hang").
_stub_op() {
    local mode="$1"
    {
        printf '#!/bin/bash\n'
        printf 'echo "$*" >>"%s/op.calls"\n' "$TEST_TEMP_DIR"
        if [ "$mode" = "hang" ]; then
            printf '[ "$1" = whoami ] && exec sleep 30\n'
        else
            printf '[ "$1" = whoami ] && exit %s\n' "$mode"
        fi
        printf 'exit 0\n'
    } >"$TEST_TEMP_DIR/bin/op"
    chmod +x "$TEST_TEMP_DIR/bin/op"
}

# Run a snippet with op-usable.sh sourced in a clean, sandboxed bash.
# Extra NAME=value args go into the environment.
_probe() {
    local snippet="$1"
    shift
    command env -i BASH_ENV= HOME="$TEST_TEMP_DIR" \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        OP_WHOAMI_CACHE_DIR="$TEST_TEMP_DIR/cache" \
        CONTAINER_CREDENTIAL_ENV_FILE="$TEST_TEMP_DIR/credential-env" \
        "$@" \
        bash -c '. "$1"; '"$snippet" _ "$SOURCE_FILE"
}

_usable() {
    _probe 'if op_is_usable; then echo yes; else echo no; fi' "$@"
}

_calls() { command grep -c "whoami" "$TEST_TEMP_DIR/op.calls" 2>/dev/null || true; }

# ----------------------------------------------------------------------------
# Detection order
# ----------------------------------------------------------------------------

test_no_op_binary_not_usable() {
    # A PATH holding only the tools the helper needs — never a real op, which
    # an image with INCLUDE_OP=true has in /usr/bin.
    local tools="$TEST_TEMP_DIR/tools" t out
    mkdir -p "$tools"
    for t in bash id sha256sum cut date stat head rm grep timeout; do
        ln -s "$(command -v "$t")" "$tools/$t"
    done
    out=$(command env -i BASH_ENV= HOME="$TEST_TEMP_DIR" PATH="$tools" \
        OP_SERVICE_ACCOUNT_TOKEN=tok OP_WHOAMI_CACHE_DIR="$TEST_TEMP_DIR/cache" \
        "$tools/bash" -c '. "$1"; op_is_usable && echo yes || echo no' _ "$SOURCE_FILE")
    assert_equals "no" "$out" "No op on PATH: not usable even with a token"
}

test_token_fast_path_no_probe() {
    _stub_op 1
    assert_equals "yes" "$(_usable OP_SERVICE_ACCOUNT_TOKEN=tok)" \
        "Service account token: usable"
    assert_equals "0" "$(_calls)" "Token fast path must not spawn op whoami"
}

test_connect_no_probe() {
    _stub_op 1
    assert_equals "yes" "$(_usable OP_CONNECT_HOST=http://c OP_CONNECT_TOKEN=t)" \
        "Connect host + token: usable"
    assert_equals "0" "$(_calls)" "Connect path must not spawn op whoami"
    assert_equals "no" "$(_usable OP_CONNECT_HOST=http://c)" \
        "Connect host without token is not enough"
}

test_whoami_success_usable() {
    _stub_op 0
    assert_equals "yes" "$(_usable)" "No token, but op whoami succeeds: usable"
    assert_equals "1" "$(_calls)" "Exactly one whoami probe"
}

test_whoami_failure_not_usable() {
    _stub_op 1
    assert_equals "no" "$(_usable)" "No token and op whoami fails: not usable"
}

test_probe_disabled() {
    _stub_op 0
    assert_equals "no" "$(_usable OP_NO_WHOAMI_PROBE=true)" \
        "OP_NO_WHOAMI_PROBE=true: token/Connect only"
    assert_equals "0" "$(_calls)" "Disabled probe must not spawn op"
}

# ----------------------------------------------------------------------------
# Never hang, never prompt
# ----------------------------------------------------------------------------

test_hanging_whoami_is_bounded() {
    _stub_op hang
    local start end out
    start=$(command date +%s)
    out=$(_usable OP_WHOAMI_TIMEOUT=1)
    end=$(command date +%s)
    assert_equals "no" "$out" "A hanging op whoami counts as not usable"
    if [ $((end - start)) -le 4 ]; then
        pass_test "Hanging whoami returned in $((end - start))s (bound 1s + kill grace)"
    else
        fail_test "Hanging whoami took $((end - start))s — the probe is not bounded"
    fi
}

test_whoami_stdin_closed() {
    # A stub that would block reading a sign-in answer from stdin.
    command cat >"$TEST_TEMP_DIR/bin/op" <<'EOF'
#!/bin/bash
[ "$1" = whoami ] || exit 0
read -r answer && [ "$answer" = "y" ] && exit 0
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/op"
    local out
    out=$(printf 'y\n' | _usable OP_WHOAMI_TIMEOUT=2)
    assert_equals "no" "$out" "op whoami must get /dev/null stdin, never the caller's"
}

# ----------------------------------------------------------------------------
# Caches
# ----------------------------------------------------------------------------

test_per_process_memo() {
    _stub_op 0
    _probe 'op_is_usable; op_is_usable; op_is_usable' OP_WHOAMI_CACHE_DIR=/nonexistent/x >/dev/null
    assert_equals "1" "$(_calls)" "Repeated calls in one process probe once"
}

test_positive_cache_shared_across_processes() {
    _stub_op 0
    _usable >/dev/null
    _usable >/dev/null
    assert_equals "1" "$(_calls)" "A fresh 'ok' verdict is reused by the next process"
}

test_negative_cache_expires() {
    _stub_op 1
    _usable >/dev/null
    _usable >/dev/null
    assert_equals "1" "$(_calls)" "A fresh 'no' verdict is reused within its TTL"
    _usable OP_USABLE_NEGATIVE_TTL=0 >/dev/null
    assert_equals "2" "$(_calls)" "An expired 'no' verdict is re-probed"
}

test_negative_cache_keyed_on_op_path() {
    _stub_op 1
    _usable >/dev/null
    # A provider shim at a DIFFERENT path must not inherit the real op's "no".
    mkdir -p "$TEST_TEMP_DIR/shims"
    printf '#!/bin/bash\necho "shim $*" >>"%s/op.calls"\n[ "$1" = whoami ] && exit 0\nexit 0\n' \
        "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/shims/op"
    chmod +x "$TEST_TEMP_DIR/shims/op"
    local out
    out=$(command env -i BASH_ENV= HOME="$TEST_TEMP_DIR" \
        PATH="$TEST_TEMP_DIR/shims:$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        OP_WHOAMI_CACHE_DIR="$TEST_TEMP_DIR/cache" \
        bash -c '. "$1"; op_is_usable && echo yes || echo no' _ "$SOURCE_FILE")
    assert_equals "yes" "$out" "A shim at a new path is probed, not shadowed by the old 'no'"
}

test_negative_memo_expires_in_long_lived_process() {
    _stub_op 1
    local out
    out=$(_probe 'op_is_usable; SECONDS=100; op_is_usable; echo done' \
        OP_WHOAMI_CACHE_DIR=/nonexistent/x OP_USABLE_NEGATIVE_TTL=30)
    assert_equals "2" "$(_calls)" "A long-lived poller re-probes once its 'no' memo expires"
}

# ----------------------------------------------------------------------------
# credential_env_load (pre-secrets hook hand-off)
# ----------------------------------------------------------------------------

test_handoff_absent_is_noop() {
    local out
    out=$(_probe 'credential_env_load; echo "rc=$?"')
    assert_equals "rc=0" "$out" "Missing hand-off file: no-op, returns 0"
}

test_handoff_loads_and_exports() {
    (umask 077 && printf 'PROVIDER_MARK=from-hook\n' >"$TEST_TEMP_DIR/credential-env")
    local out
    out=$(_probe 'credential_env_load; bash -c "echo \${PROVIDER_MARK:-unset}"')
    assert_equals "from-hook" "$out" "Hand-off assignments are exported to children"
}

test_handoff_refuses_world_writable() {
    printf 'PROVIDER_MARK=injected\n' >"$TEST_TEMP_DIR/credential-env"
    chmod 666 "$TEST_TEMP_DIR/credential-env"
    local out
    out=$(_probe 'credential_env_load 2>/dev/null; echo "${PROVIDER_MARK:-unset}"')
    assert_equals "unset" "$out" "A world-writable hand-off file is not sourced"
}

test_handoff_refuses_group_writable() {
    printf 'PROVIDER_MARK=injected\n' >"$TEST_TEMP_DIR/credential-env"
    chmod 620 "$TEST_TEMP_DIR/credential-env"
    local out
    out=$(_probe 'credential_env_load 2>/dev/null; echo "${PROVIDER_MARK:-unset}"')
    assert_equals "unset" "$out" "A group-writable hand-off file is not sourced"
}

test_handoff_refuses_symlink() {
    (umask 077 && printf 'PROVIDER_MARK=via-link\n' >"$TEST_TEMP_DIR/real-env")
    ln -s "$TEST_TEMP_DIR/real-env" "$TEST_TEMP_DIR/credential-env"
    local out
    out=$(_probe 'credential_env_load 2>&1; echo "${PROVIDER_MARK:-unset}"')
    assert_contains "$out" "not a regular file" \
        "A symlink is refused by the symlink guard itself (stat %a on a link reads 777, so the perms check alone would mask a missing guard)"
    assert_contains "$out" "unset" "A symlinked hand-off file is not sourced"
}

test_handoff_safe_under_strict_mode() {
    (umask 077 && printf 'false\nPROVIDER_MARK=after-false\n' >"$TEST_TEMP_DIR/credential-env")
    local out
    out=$(_probe 'set -euo pipefail; credential_env_load; echo "survived ${PROVIDER_MARK:-unset}"')
    assert_contains "$out" "survived" \
        "A failing line in the hand-off must not abort a set -e caller"
}

test_handoff_restores_allexport() {
    (umask 077 && printf 'A=1\n' >"$TEST_TEMP_DIR/credential-env")
    local out
    out=$(_probe 'credential_env_load; case $- in *a*) echo on ;; *) echo off ;; esac')
    assert_equals "off" "$out" "allexport is restored after loading"
}

# ----------------------------------------------------------------------------
# BASH_ENV safety (#1711 item E)
# ----------------------------------------------------------------------------

test_missing_bash_env_file_is_harmless() {
    _stub_op 0
    local out
    out=$(command env -i BASH_ENV=/nonexistent/provider-env HOME="$TEST_TEMP_DIR" \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" OP_WHOAMI_CACHE_DIR="$TEST_TEMP_DIR/cache" \
        bash -c '. "$1"; op_is_usable && echo yes' _ "$SOURCE_FILE" 2>&1)
    assert_equals "yes" "$out" "BASH_ENV pointing at a missing file breaks nothing"
}

run_test_with_setup test_no_op_binary_not_usable "No op binary → not usable"
run_test_with_setup test_token_fast_path_no_probe "Service account token → usable, no whoami subprocess"
run_test_with_setup test_connect_no_probe "Connect host+token → usable, no whoami subprocess"
run_test_with_setup test_whoami_success_usable "No token + op whoami ok → usable"
run_test_with_setup test_whoami_failure_not_usable "No token + op whoami fails → not usable"
run_test_with_setup test_probe_disabled "OP_NO_WHOAMI_PROBE=true disables the probe"
run_test_with_setup test_hanging_whoami_is_bounded "A hanging op whoami is bounded by OP_WHOAMI_TIMEOUT"
run_test_with_setup test_whoami_stdin_closed "op whoami never reads the caller's stdin"
run_test_with_setup test_per_process_memo "Per-process memo: one probe per process"
run_test_with_setup test_positive_cache_shared_across_processes "Positive verdict shared across processes"
run_test_with_setup test_negative_cache_expires "Negative verdict reused within TTL, re-probed after"
run_test_with_setup test_negative_cache_keyed_on_op_path "Negative verdict keyed on op path (shims not shadowed)"
run_test_with_setup test_negative_memo_expires_in_long_lived_process "Negative memo expires in a long-lived process"
run_test_with_setup test_handoff_absent_is_noop "credential_env_load: absent file is a no-op"
run_test_with_setup test_handoff_loads_and_exports "credential_env_load: loads and exports"
run_test_with_setup test_handoff_refuses_world_writable "credential_env_load: refuses world-writable file"
run_test_with_setup test_handoff_refuses_group_writable "credential_env_load: refuses group-writable file"
run_test_with_setup test_handoff_refuses_symlink "credential_env_load: refuses symlink"
run_test_with_setup test_handoff_safe_under_strict_mode "credential_env_load: safe under set -euo pipefail"
run_test_with_setup test_handoff_restores_allexport "credential_env_load: restores allexport"
run_test_with_setup test_missing_bash_env_file_is_harmless "BASH_ENV pointing at a missing file is harmless"

# Generate test report
generate_report
