#!/usr/bin/env bash
# Unit tests for lib/runtime/30-credential-setup.sh (#1711)
#
# The pre-secrets hook runner: CONTAINER_CREDENTIAL_SETUP_CMD then
# pre-secrets.d/*.sh, each bounded and failure-tolerant, handing env forward
# through CONTAINER_CREDENTIAL_ENV_FILE to later startup scripts.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "30-credential-setup.sh (pre-secrets hook) Tests"

# Overridable so a mutated scratch copy can be checked against this suite.
SCRIPT="${CREDENTIAL_SETUP_SCRIPT:-$PROJECT_ROOT/lib/runtime/30-credential-setup.sh}"
OP_USABLE="$PROJECT_ROOT/lib/runtime/lib/op-usable.sh"

setup() {
    TEST_TEMP_DIR="$TEST_SCRATCH_BASE/cred-setup-$$-$RANDOM"
    HOOK_DIR="$TEST_TEMP_DIR/ws/proj/.devcontainer/pre-secrets.d"
    ENV_FILE="$TEST_TEMP_DIR/credential-env"
    mkdir -p "$HOOK_DIR"
    : >"$TEST_TEMP_DIR/order"
}

teardown() {
    command rm -rf "${TEST_TEMP_DIR:-}" 2>/dev/null || true
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

# Run the hook runner sandboxed. Extra NAME=value args go into its env.
_run() {
    command env -i BASH_ENV= HOME="$TEST_TEMP_DIR" PATH="/usr/bin:/bin" \
        CREDENTIAL_SETUP_HOOK_GLOB="$TEST_TEMP_DIR/ws/*/.devcontainer/pre-secrets.d/*.sh" \
        CONTAINER_CREDENTIAL_ENV_FILE="$ENV_FILE" \
        CREDENTIAL_SETUP_HOOKS="${HOOKS_FLAG-true}" \
        "$@" bash "$SCRIPT" 2>&1
}

_hook() {
    local name="$1" body="$2"
    printf '#!/bin/bash\n%s\n' "$body" >"$HOOK_DIR/$name"
}

test_noop_without_hooks() {
    local out rc=0
    out=$(_run) || rc=$?
    assert_equals "0" "$rc" "No hooks: exits 0"
    assert_equals "" "$out" "No hooks: prints nothing"
    assert_file_not_exists "$ENV_FILE" "No hooks: hand-off file is not created"
}

test_cmd_runs_before_hooks_in_order() {
    _hook 20-b.sh "echo b >>'$TEST_TEMP_DIR/order'"
    _hook 10-a.sh "echo a >>'$TEST_TEMP_DIR/order'"
    _run CONTAINER_CREDENTIAL_SETUP_CMD="echo cmd >>'$TEST_TEMP_DIR/order'" >/dev/null
    assert_equals "cmd a b" "$(command tr '\n' ' ' <"$TEST_TEMP_DIR/order" | command sed 's/ $//')" \
        "CONTAINER_CREDENTIAL_SETUP_CMD first, then hooks in sorted order"
}

test_failing_hook_does_not_stop_next() {
    _hook 10-bad.sh "exit 3"
    _hook 20-good.sh "echo good >>'$TEST_TEMP_DIR/order'"
    local out rc=0
    out=$(_run) || rc=$?
    assert_equals "0" "$rc" "A failing hook never fails the startup script"
    assert_contains "$out" "10-bad.sh failed (exit 3)" "The failure is logged with its exit code"
    assert_file_contains "$TEST_TEMP_DIR/order" "good" "The next hook still runs"
}

test_hanging_hook_is_bounded() {
    _hook 10-hang.sh "sleep 30"
    _hook 20-after.sh "echo after >>'$TEST_TEMP_DIR/order'"
    local start end out
    start=$(command date +%s)
    out=$(_run CREDENTIAL_SETUP_TIMEOUT=1)
    end=$(command date +%s)
    assert_contains "$out" "timed out after 1s" "A hanging hook is reported as timed out"
    assert_file_contains "$TEST_TEMP_DIR/order" "after" "The next hook still runs after a timeout"
    if [ $((end - start)) -le 8 ]; then
        pass_test "Hanging hook bounded ($((end - start))s)"
    else
        fail_test "Hanging hook took $((end - start))s — not bounded"
    fi
}

test_symlinked_hook_ignored() {
    printf '#!/bin/bash\necho linked >>"%s/order"\n' "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/real.sh"
    ln -s "$TEST_TEMP_DIR/real.sh" "$HOOK_DIR/10-link.sh"
    _hook 20-real.sh "echo real >>'$TEST_TEMP_DIR/order'"
    _run >/dev/null
    assert_file_not_contains "$TEST_TEMP_DIR/order" "linked" "Symlinked hooks are not run"
    assert_file_contains "$TEST_TEMP_DIR/order" "real" "Regular hooks still run"
}

test_writable_hook_refused_loudly() {
    _hook 10-open.sh "echo open >>'$TEST_TEMP_DIR/order'"
    chmod 666 "$HOOK_DIR/10-open.sh"
    _hook 20-group.sh "echo group >>'$TEST_TEMP_DIR/order'"
    chmod 664 "$HOOK_DIR/20-group.sh"
    _hook 30-ok.sh "echo ok >>'$TEST_TEMP_DIR/order'"
    chmod 644 "$HOOK_DIR/30-ok.sh"
    local out
    out=$(_run)
    assert_file_not_contains "$TEST_TEMP_DIR/order" "open" "A world-writable hook is not run"
    assert_file_not_contains "$TEST_TEMP_DIR/order" "group" "A group-writable hook is not run"
    assert_file_contains "$TEST_TEMP_DIR/order" "ok" "A 0644 hook owned by the user still runs"
    assert_contains "$out" "ignoring hook $HOOK_DIR/10-open.sh (group/world-writable, mode 666)" \
        "The refusal names the file and the reason"
}

test_stale_handoff_cleared_when_nothing_runs() {
    # A previous boot's hooks wrote the hand-off; now hooks are switched off.
    printf 'export PATH="/old/provider/shims:$PATH"\n' >"$ENV_FILE"
    _hook 10-repo.sh "true"
    HOOKS_FLAG=false _run >/dev/null
    assert_file_not_exists "$ENV_FILE" \
        "Turning hooks off retires the stale hand-off (no old PATH re-applied)"
}

test_hooks_are_opt_in() {
    _hook 10-repo.sh "echo repo >>'$TEST_TEMP_DIR/order'"
    local out
    out=$(HOOKS_FLAG=false _run)
    assert_file_not_contains "$TEST_TEMP_DIR/order" "repo" \
        "Without CREDENTIAL_SETUP_HOOKS=true a workspace hook never runs"
    assert_contains "$out" "skipping 1 pre-secrets.d hook(s): workspace hooks are opt-in (set CREDENTIAL_SETUP_HOOKS=true)" \
        "The skip is logged with how to enable it (never silent)"
    assert_file_not_exists "$ENV_FILE" "Flag off and no command: nothing is created"
    out=$(HOOKS_FLAG='' _run)
    assert_file_not_contains "$TEST_TEMP_DIR/order" "repo" "Unset flag is off too"
}

test_setup_cmd_needs_no_opt_in() {
    _hook 10-repo.sh "echo repo >>'$TEST_TEMP_DIR/order'"
    HOOKS_FLAG=false _run CONTAINER_CREDENTIAL_SETUP_CMD="echo cmd >>'$TEST_TEMP_DIR/order'" >/dev/null
    assert_file_contains "$TEST_TEMP_DIR/order" "cmd" \
        "CONTAINER_CREDENTIAL_SETUP_CMD (operator env, not repo) runs without the opt-in"
    assert_file_not_contains "$TEST_TEMP_DIR/order" "repo" "…while workspace hooks stay off"
}

test_term_ignoring_hook_reported_as_timeout() {
    # A hook that traps TERM is KILLed after the grace period (exit 137).
    _hook 10-stubborn.sh "trap '' TERM; sleep 30"
    local out
    out=$(_run CREDENTIAL_SETUP_TIMEOUT=1)
    assert_contains "$out" "10-stubborn.sh timed out after 1s" \
        "A KILL after the grace period is reported as a timeout, not a failure"
}

test_handoff_reaches_later_consumer() {
    # The hook can only change ITS OWN process; the hand-off file is how its
    # PATH reaches 45-op-secrets (a separate process) via credential_env_load.
    mkdir -p "$TEST_TEMP_DIR/shims"
    _hook 10-provider.sh "echo 'export PATH=\"$TEST_TEMP_DIR/shims:\$PATH\"' >>\"\$CONTAINER_CREDENTIAL_ENV_FILE\""
    _run >/dev/null
    local mode out
    mode=$(command stat -c '%a' "$ENV_FILE")
    assert_equals "600" "$mode" "Hand-off file is created 0600"
    out=$(command env -i BASH_ENV= HOME="$TEST_TEMP_DIR" PATH="/usr/bin:/bin" \
        CONTAINER_CREDENTIAL_ENV_FILE="$ENV_FILE" \
        bash -c '. "$1"; credential_env_load; echo "$PATH"' _ "$OP_USABLE")
    assert_contains "$out" "$TEST_TEMP_DIR/shims" "A later process sees the hook's PATH"
}

test_stale_handoff_cleared_each_boot() {
    printf 'export STALE=1\n' >"$ENV_FILE"
    _hook 10-noop.sh "true"
    _run >/dev/null
    assert_file_not_contains "$ENV_FILE" "STALE" "A previous boot's hand-off is cleared"
}

test_missing_bash_env_file_is_harmless() {
    _hook 10-mark.sh "echo ran >>'$TEST_TEMP_DIR/order'"
    _run BASH_ENV=/nonexistent/provider-env >/dev/null
    assert_file_contains "$TEST_TEMP_DIR/order" "ran" "BASH_ENV pointing at a missing file breaks nothing"
}

test_installed_before_secret_consumers() {
    # Ordering is by filename in /etc/container/startup: 30 < 35 < 45 < 60.
    assert_file_contains "$PROJECT_ROOT/Dockerfile" "/etc/container/startup/30-credential-setup.sh" \
        "Dockerfile installs the hook runner into the every-boot startup dir"
    local n
    for n in 35-claude-auth-watcher 45-op-secrets 60-setup-git; do
        if [[ "30-credential-setup" < "$n" ]]; then
            pass_test "30-credential-setup sorts before $n"
        else
            fail_test "30-credential-setup must sort before $n"
        fi
    done
}

run_test_with_setup test_noop_without_hooks "No hooks → no-op, no hand-off file"
run_test_with_setup test_cmd_runs_before_hooks_in_order "CMD first, then hooks in sorted order"
run_test_with_setup test_failing_hook_does_not_stop_next "Failing hook logged; next hook runs; exit 0"
run_test_with_setup test_hanging_hook_is_bounded "Hanging hook bounded by CREDENTIAL_SETUP_TIMEOUT"
run_test_with_setup test_symlinked_hook_ignored "Symlinked hooks ignored"
run_test_with_setup test_writable_hook_refused_loudly "Group/world-writable hooks refused with a reason"
run_test_with_setup test_stale_handoff_cleared_when_nothing_runs "Stale hand-off cleared even when no hook runs"
run_test_with_setup test_hooks_are_opt_in "Workspace hooks are opt-in; skip is logged"
run_test_with_setup test_setup_cmd_needs_no_opt_in "CONTAINER_CREDENTIAL_SETUP_CMD runs without the opt-in"
run_test_with_setup test_term_ignoring_hook_reported_as_timeout "TERM-ignoring hook killed and logged as timeout"
run_test_with_setup test_handoff_reaches_later_consumer "Hook PATH reaches a later process via the hand-off"
run_test_with_setup test_stale_handoff_cleared_each_boot "Stale hand-off cleared each boot"
run_test_with_setup test_missing_bash_env_file_is_harmless "BASH_ENV pointing at a missing file is harmless"
run_test_with_setup test_installed_before_secret_consumers "Installed to run before 35/45/60"

# Generate test report
generate_report
