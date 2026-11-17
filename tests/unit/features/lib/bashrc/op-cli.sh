#!/usr/bin/env bash
# Behavioural tests for lib/features/lib/bashrc/op-cli.sh op gating (#1719)
#
# #1711 reordered the interactive-shell 1Password path: the secrets cache is
# checked BEFORE the auth gate (a cached shell never pays an `op whoami`), and
# the gate itself (_op_cli_ready) is token-fast-path-else-op_is_usable. These
# tests source the bashrc in a real interactive bash with a recording stub op
# and pin the observable outcome of each path, then prove each assertion
# discriminates by re-running it against a mutated scratch copy.
#
# Sandbox: the bashrc is copied to scratch with its two absolute paths
# rewritten — the cache (/dev/shm/op-secrets-cache → scratch) and op-usable.sh
# (/opt/container-runtime → this repo). The live /dev/shm cache is never read
# or written. Only OP_*_REF is exercised: OP_*_FILE_REF writes to /dev/shm.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"
init_test_framework
test_suite "op-cli bashrc op gating (behavioural)"

BASHRC_SRC="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
OP_USABLE_SRC="$PROJECT_ROOT/lib/runtime/lib/op-usable.sh"

setup() {
    TEST_TEMP_DIR="$TEST_SCRATCH_BASE/op-cli-bashrc-$$-$RANDOM"
    command mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/whoami-cache"
    CACHE_FILE="$TEST_TEMP_DIR/op-secrets-cache"
    BASHRC="$TEST_TEMP_DIR/op-cli.sh"
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

# Copy the bashrc to scratch with its absolute paths sandboxed. Fails (and
# prints why) if either rewrite matched nothing — a renamed line must not
# silently fall through to the live /dev/shm cache.
_sandbox_bashrc() {
    command sed \
        -e "s|^_OP_SECRETS_CACHE=\"/dev/shm/op-secrets-cache\"\$|_OP_SECRETS_CACHE=\"$CACHE_FILE\"|" \
        -e "s|/opt/container-runtime/lib/op-usable.sh|$OP_USABLE_SRC|g" \
        "$BASHRC_SRC" >"$BASHRC"
    if ! command grep -qF "_OP_SECRETS_CACHE=\"$CACHE_FILE\"" "$BASHRC"; then
        echo "sandbox: cache-path rewrite matched nothing"
        return 1
    fi
    if command grep -qF "/opt/container-runtime" "$BASHRC" ||
        ! command grep -qF ". $OP_USABLE_SRC" "$BASHRC"; then
        echo "sandbox: op-usable.sh rewrite did not apply"
        return 1
    fi
    if command grep -qF "/dev/shm/op-secrets-cache" "$BASHRC"; then
        echo "sandbox: live cache path still referenced"
        return 1
    fi
}

# Stub op: records every call; `whoami` exits $1; `read <ref>` prints secret:<ref>.
_stub_op() {
    {
        printf '#!/bin/bash\n'
        printf 'echo "$*" >>"%s/op.calls"\n' "$TEST_TEMP_DIR"
        printf '[ "$1" = whoami ] && exit %s\n' "$1"
        printf '[ "$1" = read ] && { printf "secret:%%s" "$2"; exit 0; }\n'
        printf 'exit 0\n'
    } >"$TEST_TEMP_DIR/bin/op"
    command chmod +x "$TEST_TEMP_DIR/bin/op"
}

_seed_cache() {
    {
        printf 'export GITHUB_TOKEN=%q\n' "from-cache"
        printf 'export GIT_USER_NAME=%q\n' "Cached User"
        printf 'export GIT_USER_EMAIL=%q\n' "cached@example.com"
    } >"$CACHE_FILE"
    command chmod 600 "$CACHE_FILE"
}

# Source $1 (a bashrc copy) in a clean interactive bash and print a one-line
# verdict: whoami/read call counts, the resolved GITHUB_TOKEN, and whether the
# cache file exists and carries the token. -i forces the synchronous
# interactive path (the non-interactive path backgrounds the work and races).
# BASH_ENV is emptied: /etc/bash_env rebuilds PATH and would bypass the stub.
# Extra NAME=value args go into the child's environment.
_verdict() {
    local bashrc="$1" token whoami reads cache
    shift
    token=$(command env -i BASH_ENV= HOME="$TEST_TEMP_DIR" \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        OP_WHOAMI_CACHE_DIR="$TEST_TEMP_DIR/whoami-cache" \
        CONTAINER_CREDENTIAL_ENV_FILE="$TEST_TEMP_DIR/credential-env" \
        OP_GITHUB_TOKEN_REF="op://Dev/GitHub/token" \
        "$@" \
        bash --norc --noprofile -i -c '. "$1"; printf "%s" "${GITHUB_TOKEN-<unset>}"' \
        _ "$bashrc" </dev/null 2>/dev/null) || true
    whoami=$(command grep -c '^whoami' "$TEST_TEMP_DIR/op.calls" || true)
    reads=$(command grep -c '^read' "$TEST_TEMP_DIR/op.calls" || true)
    if [ -f "$CACHE_FILE" ]; then
        if command grep -q '^export GITHUB_TOKEN=' "$CACHE_FILE"; then
            cache=token
        else
            cache=no-token
        fi
    else
        cache=absent
    fi
    printf 'whoami=%s read=%s token=%s cache=%s' "$whoami" "$reads" "$token" "$cache"
}

# Reset per-run observable state so the same case can re-run on a mutant.
_reset_run() {
    : >"$TEST_TEMP_DIR/op.calls"
    command rm -rf "$CACHE_FILE" "$TEST_TEMP_DIR/whoami-cache"
    command mkdir -p "$TEST_TEMP_DIR/whoami-cache"
}

# Write a mutated copy of the sandboxed bashrc ($2 = sed script) to $1 and
# fail if the mutation changed nothing (a stale anchor would make the
# mutation check pass vacuously).
_mutant() {
    local out="$1" script="$2"
    command sed -e "$script" "$BASHRC" >"$out"
    if command cmp -s "$BASHRC" "$out"; then
        echo "mutation did not apply: $script"
        return 1
    fi
    # A mutant that no longer parses would "differ" for the wrong reason.
    if ! bash -n "$out" 2>/dev/null; then
        echo "mutation broke syntax: $script"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Case runners: seed state, run a bashrc, print the verdict.
# ----------------------------------------------------------------------------

_case_cache_hit() {
    _reset_run
    _seed_cache
    _verdict "$1"
}

_case_whoami_ok() {
    _reset_run
    _verdict "$1"
}

_case_whoami_fails() {
    _reset_run
    _verdict "$1"
}

_case_token_fast_path() {
    _reset_run
    _verdict "$1" OP_SERVICE_ACCOUNT_TOKEN=sa-token
}

# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

test_sandbox_rewrites_apply() {
    local msg
    msg=$(_sandbox_bashrc) || {
        assert_equals "" "$msg" "Sandboxed copy of op-cli.sh"
        return
    }
    assert_equals "" "$msg" "Both absolute paths rewritten to scratch/repo"
}

test_cache_hit_never_probes_op() {
    _sandbox_bashrc >/dev/null || {
        assert_equals "" "sandbox failed" "sandbox"
        return
    }
    _stub_op 0
    assert_equals "whoami=0 read=0 token=from-cache cache=token" \
        "$(_case_cache_hit "$BASHRC")" \
        "Cache hit: secrets from cache, op never spawned"

    # Mutation: gate before the cache check (the pre-#1711 order).
    local m="$TEST_TEMP_DIR/mutant.sh" err
    err=$(_mutant "$m" '/if \[ -f "\$_OP_SECRETS_CACHE" \] && \[ -O/i\    _op_cli_ready || return 0') ||
        {
            assert_equals "" "$err" "mutation applies"
            return
        }
    assert_equals "whoami=1 read=0 token=from-cache cache=token" \
        "$(_case_cache_hit "$m")" \
        "Mutant (gate before cache check) is caught: whoami probed"
}

test_no_token_whoami_ok_resolves_and_caches() {
    _sandbox_bashrc >/dev/null || {
        assert_equals "" "sandbox failed" "sandbox"
        return
    }
    _stub_op 0
    assert_equals "whoami=1 read=1 token=secret:op://Dev/GitHub/token cache=token" \
        "$(_case_whoami_ok "$BASHRC")" \
        "No token + whoami ok: OP_*_REF resolved and cache written"

    # Mutation: gate ignores op_is_usable (token-only, the pre-#1711 gate).
    local m="$TEST_TEMP_DIR/mutant.sh" err
    err=$(_mutant "$m" 's/&& op_is_usable$/\&\& false/') ||
        {
            assert_equals "" "$err" "mutation applies"
            return
        }
    assert_equals "whoami=0 read=0 token=<unset> cache=absent" \
        "$(_case_whoami_ok "$m")" \
        "Mutant (token-only gate) is caught: secret not resolved"
}

test_no_token_whoami_fails_reads_nothing() {
    _sandbox_bashrc >/dev/null || {
        assert_equals "" "sandbox failed" "sandbox"
        return
    }
    _stub_op 1
    local got
    got=$(_case_whoami_fails "$BASHRC")
    assert_equals "read=0 token=<unset> cache=absent" "${got#whoami=* }" \
        "No token + whoami fails: no op read, no secret, no cache"
    assert_not_equals "whoami=0" "${got%% *}" "The gate actually probed whoami"

    # Mutation: gate always passes.
    local m="$TEST_TEMP_DIR/mutant.sh" err
    err=$(_mutant "$m" 's/&& op_is_usable$/|| true/') ||
        {
            assert_equals "" "$err" "mutation applies"
            return
        }
    got=$(_case_whoami_fails "$m")
    assert_equals "read=1 token=secret:op://Dev/GitHub/token cache=token" "${got#whoami=* }" \
        "Mutant (gate always open) is caught: op read / cache write"
}

test_token_fast_path_skips_whoami() {
    _sandbox_bashrc >/dev/null || {
        assert_equals "" "sandbox failed" "sandbox"
        return
    }
    _stub_op 1
    assert_equals "whoami=0 read=1 token=secret:op://Dev/GitHub/token cache=token" \
        "$(_case_token_fast_path "$BASHRC")" \
        "Service account token: secrets resolve without an op whoami"
}

# The _op_cli_ready token fast path is only observable when op-usable.sh is
# absent (an image without the runtime lib): op_is_usable has its own token
# fast path, so with it present, deleting the bashrc's is an equivalent mutant.
test_token_fast_path_without_op_usable() {
    _sandbox_bashrc >/dev/null || {
        assert_equals "" "sandbox failed" "sandbox"
        return
    }
    local nolib="$TEST_TEMP_DIR/op-cli-nolib.sh"
    command sed -e "s|$OP_USABLE_SRC|$TEST_TEMP_DIR/absent/op-usable.sh|g" \
        "$BASHRC" >"$nolib"
    BASHRC="$nolib"
    _stub_op 1
    assert_equals "whoami=0 read=1 token=secret:op://Dev/GitHub/token cache=token" \
        "$(_case_token_fast_path "$BASHRC")" \
        "No op-usable.sh + token: secrets still resolve"
    _reset_run
    assert_equals "whoami=0 read=0 token=<unset> cache=absent" \
        "$(_verdict "$BASHRC")" \
        "No op-usable.sh + no token: gate closed, nothing read"

    # Mutation: drop the token fast path.
    local m="$TEST_TEMP_DIR/mutant.sh" err
    err=$(_mutant "$m" '/\[ -n "\${OP_SERVICE_ACCOUNT_TOKEN:+set}" \] && return 0/d') ||
        {
            assert_equals "" "$err" "mutation applies"
            return
        }
    assert_equals "whoami=0 read=0 token=<unset> cache=absent" \
        "$(_case_token_fast_path "$m")" \
        "Mutant (no token fast path) is caught"
}

run_test_with_setup test_sandbox_rewrites_apply "Sandbox rewrites the cache + op-usable.sh paths"
run_test_with_setup test_cache_hit_never_probes_op "Cache hit → op whoami never called (mutation-checked)"
run_test_with_setup test_no_token_whoami_ok_resolves_and_caches "No token + whoami ok → secrets resolve, cache written (mutation-checked)"
run_test_with_setup test_no_token_whoami_fails_reads_nothing "No token + whoami fails → no op read, no cache (mutation-checked)"
run_test_with_setup test_token_fast_path_skips_whoami "Token fast path → no whoami"
run_test_with_setup test_token_fast_path_without_op_usable "No op-usable.sh: token fast path still opens the gate (mutation-checked)"

generate_report
