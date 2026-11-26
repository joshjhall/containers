#!/usr/bin/env bash
# Regression test for issue #1789: the test framework must turn commit/tag
# signing off for every git operation a unit test runs — including git run by a
# CHILD bash whose BASH_ENV re-exports the operator's signing config.
#
# The devcontainer injects commit.gpgsign=true / tag.gpgsign=true /
# gpg.ssh.program through GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n /
# GIT_CONFIG_VALUE_n, and BASH_ENV=/etc/bash_env re-sources the drumknott env
# (resetting GIT_CONFIG_COUNT=8) in every non-interactive bash. framework.sh
# therefore puts its override in GIT_CONFIG_PARAMETERS, which that chain never
# touches and which git applies after the GIT_CONFIG_COUNT entries.
#
# Each case runs in a CHILD shell under `env -i` with a hostile signing env whose
# gpg.ssh.program is a stub that always exits 1. Control cases prove the stub
# really breaks signing without the framework, and that the BASH_ENV hook really
# resets the count in the child, so the "unsigned" cases cannot pass because
# the stub or the hook happened to be inert.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

# Overridable so the guard can be mutation-checked against a scratch copy of
# the framework without touching the tracked file.
FRAMEWORK_SH="${SIGNING_TEST_FRAMEWORK_SH:-$SCRIPT_DIR/../framework.sh}"

test_suite "test framework disables git signing (#1789)"

NOSIGN="'commit.gpgsign'='false' 'tag.gpgsign'='false'"

# Build the always-failing signer, a scratch HOME/global config, and a BASH_ENV
# script that mimics /etc/bashrc.d/90-drumknott.sh: it re-exports the hostile
# signing config (GIT_CONFIG_COUNT=6 + entries) in every non-interactive bash.
_prepare_hostile() {
    command mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/home"
    command printf '#!/bin/sh\necho "stub signer refused" >&2\nexit 1\n' \
        >"$TEST_TEMP_DIR/bin/failing-signer"
    command chmod +x "$TEST_TEMP_DIR/bin/failing-signer"
    command printf '[core]\n\tautocrlf = false\n' >"$TEST_TEMP_DIR/home/.gitconfig"
    {
        command printf 'export GIT_CONFIG_COUNT=6\n'
        command printf 'export GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0="Test User"\n'
        command printf 'export GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=test@example.com\n'
        command printf 'export GIT_CONFIG_KEY_2=gpg.format GIT_CONFIG_VALUE_2=ssh\n'
        command printf 'export GIT_CONFIG_KEY_3=gpg.ssh.program GIT_CONFIG_VALUE_3=%q\n' \
            "$TEST_TEMP_DIR/bin/failing-signer"
        command printf 'export GIT_CONFIG_KEY_4=commit.gpgsign GIT_CONFIG_VALUE_4=true\n'
        command printf 'export GIT_CONFIG_KEY_5=tag.gpgsign GIT_CONFIG_VALUE_5=true\n'
    } >"$TEST_TEMP_DIR/bash_env"
}

# Run $2 in a fresh bash with the hostile signing env. $1=yes sources the
# framework (and runs init_test_framework) first; $1=no runs the body bare.
# BASH_ENV points at the hostile hook, so the outer shell AND every child bash
# get the signing config re-exported, exactly as in the devcontainer.
#
# stdin is /dev/null on purpose: under `env -i` SHLVL is unset, and bash skips
# BASH_ENV (running ~/.bashrc instead) when SHLVL < 2 and stdin is a network
# socket — which it intermittently is under some harnesses. That made the hook
# silently not fire. The hook_applied guard below makes any such regression
# loud instead of letting a case pass (or fail) for the wrong reason.
_run_hostile() {
    local with_framework="$1" body="$2" prelude=''
    prelude='[ "${GIT_CONFIG_COUNT:-}" = 6 ] || { /usr/bin/echo "hook_not_applied"; exit 0; }; '
    if [ "$with_framework" = yes ]; then
        prelude+='source "$FRAMEWORK_SH" >/dev/null 2>&1; init_test_framework >/dev/null 2>&1; '
    fi
    /usr/bin/env -i \
        PATH="/usr/bin:/bin" \
        HOME="$TEST_TEMP_DIR/home" \
        TERM="dumb" \
        SKIP_DOCKER_CHECK=true \
        FRAMEWORK_SH="$FRAMEWORK_SH" \
        BASH_ENV="$TEST_TEMP_DIR/bash_env" \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL="$TEST_TEMP_DIR/home/.gitconfig" \
        REPO="$TEST_TEMP_DIR/repo" \
        /bin/bash -c "${prelude}${body}" </dev/null
}

# Commit in a fresh scratch repo; report rc and whether HEAD carries gpgsig.
COMMIT_BODY='
    /usr/bin/git init -q "$REPO" || exit 9
    cd "$REPO" || exit 9
    if /usr/bin/git commit -q --allow-empty -m init >/dev/null 2>&1; then
        /usr/bin/echo "commit_rc=0"
    else
        /usr/bin/echo "commit_rc=fail"
        exit 0
    fi
    obj=$(/usr/bin/git cat-file commit HEAD) || exit 9
    if /usr/bin/grep -q "^gpgsig" <<<"$obj"; then
        /usr/bin/echo "gpgsig=present"
    else
        /usr/bin/echo "gpgsig=absent"
    fi
'

# Control: the hostile env really breaks a commit when the framework is absent.
test_control_stub_signer_breaks_commit() {
    _prepare_hostile
    local out
    out=$(_run_hostile no '
        /usr/bin/git init -q "$REPO" && cd "$REPO" || exit 9
        /usr/bin/git commit -q --allow-empty -m init >/dev/null 2>&1 &&
            /usr/bin/echo "commit_rc=0" || /usr/bin/echo "commit_rc=fail"
        # Prove the failure is the SIGNER, not a missing identity: the same
        # commit with signing explicitly off must succeed.
        /usr/bin/git -c commit.gpgsign=false commit -q --allow-empty -m nosign >/dev/null 2>&1 &&
            /usr/bin/echo "unsigned_ok=1" || /usr/bin/echo "unsigned_ok=0"
    ')
    assert_contains "$out" "commit_rc=fail" \
        "without the framework the always-failing signer must break git commit"
    assert_contains "$out" "unsigned_ok=1" \
        "the same commit with signing off must succeed, so the failure is the signer"
    assert_not_contains "$out" "hook_not_applied" "the hostile BASH_ENV hook must have applied"
}

test_framework_commit_is_unsigned() {
    _prepare_hostile
    local out
    out=$(_run_hostile yes "$COMMIT_BODY")
    assert_contains "$out" "commit_rc=0" "scratch commit must succeed under the framework"
    assert_contains "$out" "gpgsig=absent" "scratch commit must carry no gpgsig header"
    assert_not_contains "$out" "gpgsig=present" "scratch commit must not be signed"
}

# The operator-reported failure mode: a test spawns `bash -c`, BASH_ENV re-runs
# the signing hook in that child and resets GIT_CONFIG_COUNT, and the child's
# commit must STILL be unsigned. The child echoes its count first so the test
# proves the hook really fired (count reset to 6) — otherwise the case would
# pass vacuously if BASH_ENV stopped being honoured.
test_child_bash_with_bash_env_commits_unsigned() {
    _prepare_hostile
    local out
    out=$(_run_hostile yes '
        export GIT_CONFIG_COUNT=99 # proves the child re-exports it via BASH_ENV
        /bin/bash -c '\''/usr/bin/echo "child_count=$GIT_CONFIG_COUNT"'"$COMMIT_BODY"\''
    ')
    assert_contains "$out" "child_count=6" \
        "control: the BASH_ENV hook must reset GIT_CONFIG_COUNT in the child bash"
    assert_contains "$out" "commit_rc=0" "child-bash commit must succeed under the framework"
    assert_contains "$out" "gpgsig=absent" "child-bash commit must carry no gpgsig header"
}

test_framework_annotated_tag_is_unsigned() {
    _prepare_hostile
    local out
    out=$(_run_hostile yes '
        /usr/bin/git init -q "$REPO" && cd "$REPO" || exit 9
        /usr/bin/git commit -q --allow-empty -m init >/dev/null 2>&1 || { /usr/bin/echo "commit_rc=fail"; exit 0; }
        if /usr/bin/git tag -a -m "v1" v1 >/dev/null 2>&1; then
            /usr/bin/echo "tag_rc=0"
        else
            /usr/bin/echo "tag_rc=fail"; exit 0
        fi
        obj=$(/usr/bin/git cat-file tag v1) || exit 9
        if /usr/bin/grep -q "BEGIN SSH SIGNATURE" <<<"$obj"; then
            /usr/bin/echo "tagsig=present"
        else
            /usr/bin/echo "tagsig=absent"
        fi
    ')
    assert_contains "$out" "tag_rc=0" "annotated tag must succeed under the framework"
    assert_contains "$out" "tagsig=absent" "annotated tag must carry no signature"
}

# A test that deliberately wants signing on (`git -c commit.gpgsign=true`) must
# still get it — the override is a default, not a lock.
test_explicit_git_c_still_wins() {
    _prepare_hostile
    local out
    out=$(_run_hostile yes '
        /usr/bin/echo "default=$(/usr/bin/git config --get commit.gpgsign)"
        /usr/bin/echo "explicit=$(/usr/bin/git -c commit.gpgsign=true config --get commit.gpgsign)"
        /usr/bin/git init -q "$REPO" && cd "$REPO" || exit 9
        if /usr/bin/git -c commit.gpgsign=true commit -q --allow-empty -m x >/dev/null 2>&1; then
            /usr/bin/echo "signed_commit=succeeded"
        else
            /usr/bin/echo "signed_commit=refused"
        fi
    ')
    # default=false proves the framework flipped it, so explicit=true is a real
    # override rather than the untouched hostile value.
    assert_contains "$out" "default=false" "framework default must be signing off"
    assert_contains "$out" "explicit=true" "an explicit git -c must override the framework default"
    assert_contains "$out" "signed_commit=refused" \
        "explicit git -c commit.gpgsign=true must really attempt signing (stub signer refuses)"
}

# init_test_framework re-asserts the override: a consumer that clears
# GIT_CONFIG_PARAMETERS after sourcing gets it back on re-init.
test_init_reasserts_after_clear() {
    _prepare_hostile
    local out
    out=$(/usr/bin/env -i PATH="/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" \
        SKIP_DOCKER_CHECK=true FRAMEWORK_SH="$FRAMEWORK_SH" \
        /bin/bash -c 'source "$FRAMEWORK_SH" >/dev/null 2>&1
            unset GIT_CONFIG_PARAMETERS
            init_test_framework >/dev/null 2>&1
            /usr/bin/echo "params=|${GIT_CONFIG_PARAMETERS:-}|"')
    assert_equals "params=|$NOSIGN|" "$out" "init_test_framework must restore the override"
}

# Source the framework in a minimal env with only the given args and report
# GIT_CONFIG_PARAMETERS and GIT_CONFIG_COUNT afterwards. Delimited with | so the
# equality assertion compares the exact value, not a substring.
_source_with_env() {
    /usr/bin/env -i PATH="/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" \
        SKIP_DOCKER_CHECK=true FRAMEWORK_SH="$FRAMEWORK_SH" NOSIGN="$NOSIGN" "$@" \
        /bin/bash -c 'source "$FRAMEWORK_SH" >/dev/null 2>&1 || { /usr/bin/echo source_failed; exit 0; }
            # Module scope alone (before any re-application) must already set it.
            [ -n "${GIT_CONFIG_PARAMETERS:-}" ] && [ "${GIT_CONFIG_PARAMETERS%"$NOSIGN"}" != "$GIT_CONFIG_PARAMETERS" ] ||
                { /usr/bin/echo "module_scope_missing"; exit 0; }
            init_test_framework >/dev/null 2>&1
            tf_disable_git_signing
            nested=$(/bin/bash -c '\''source "$FRAMEWORK_SH" >/dev/null 2>&1; /usr/bin/printf "%s" "$GIT_CONFIG_PARAMETERS"'\'')
            /usr/bin/echo "params=|${GIT_CONFIG_PARAMETERS:-}| count=${GIT_CONFIG_COUNT:-unset} nested=|$nested|"'
}

# With nothing pre-set, the override is exactly the two entries, and re-init +
# a direct call + a nested re-source do not append again.
test_params_set_once_and_idempotent() {
    _prepare_hostile
    local out
    out=$(_source_with_env)
    assert_equals "params=|$NOSIGN| count=unset nested=|$NOSIGN|" "$out" \
        "override set exactly once; GIT_CONFIG_COUNT left untouched"
}

# Pre-existing GIT_CONFIG_PARAMETERS entries are preserved, override appended
# after them (so it wins), still exactly once.
test_existing_params_preserved() {
    _prepare_hostile
    local out
    out=$(_source_with_env GIT_CONFIG_PARAMETERS="'user.name'='Keep Me'")
    assert_equals "params=|'user.name'='Keep Me' $NOSIGN| count=unset nested=|'user.name'='Keep Me' $NOSIGN|" "$out" \
        "existing GIT_CONFIG_PARAMETERS kept, override appended once"
}

# A pre-existing params value that merely CONTAINS the override somewhere other
# than at the end (so a later entry re-enables signing) must not be treated as
# already applied — the override has to be last to win.
test_partial_or_earlier_match_still_appends() {
    _prepare_hostile
    local out
    out=$(_source_with_env GIT_CONFIG_PARAMETERS="$NOSIGN 'commit.gpgsign'='true'")
    assert_equals "params=|$NOSIGN 'commit.gpgsign'='true' $NOSIGN| count=unset nested=|$NOSIGN 'commit.gpgsign'='true' $NOSIGN|" "$out" \
        "an override followed by a re-enable must be appended again"
}

# The operator's GIT_CONFIG_COUNT entries are never modified.
test_config_count_entries_untouched() {
    _prepare_hostile
    local out
    out=$(_source_with_env GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=true)
    assert_contains "$out" "count=1 " "GIT_CONFIG_COUNT must not be changed"

    # ...and the override still beats that untouched COUNT entry.
    out=$(/usr/bin/env -i PATH="/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" \
        SKIP_DOCKER_CHECK=true FRAMEWORK_SH="$FRAMEWORK_SH" GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL="$TEST_TEMP_DIR/home/.gitconfig" GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=true \
        /bin/bash -c 'source "$FRAMEWORK_SH" >/dev/null 2>&1; /usr/bin/git config --get commit.gpgsign')
    assert_equals "false" "$out" "override must win over a GIT_CONFIG_COUNT commit.gpgsign=true"
}

# The override lives only in the environment: no git config file is written,
# so operator commits outside the framework stay signed.
test_framework_does_not_touch_git_config_files() {
    _prepare_hostile
    local before after out
    before=$(command cat "$TEST_TEMP_DIR/home/.gitconfig")
    out=$(_run_hostile yes '/usr/bin/echo ran')
    after=$(command cat "$TEST_TEMP_DIR/home/.gitconfig")
    assert_equals "ran" "$out" "framework child shell should run"
    assert_equals "$before" "$after" "global git config must be byte-identical"

    # Outside the framework the hostile env still demands signing.
    out=$(_run_hostile no '/usr/bin/git config --get commit.gpgsign')
    assert_equals "true" "$out" "commit.gpgsign stays true outside the framework"
}

# In-suite mutation check: a scratch copy of the framework with the override
# calls stubbed out must make the unsigned-commit scenario FAIL. Proves the
# commit cases discriminate on the override itself, without anyone having to
# re-run the mutation by hand. The tracked framework.sh is never modified.
test_mutation_without_override_commit_fails() {
    _prepare_hostile
    local src_dir mut_dir out calls
    src_dir="$(command dirname "$FRAMEWORK_SH")"
    mut_dir="$TEST_TEMP_DIR/mutant"
    command mkdir -p "$mut_dir"
    command cp "$src_dir/framework.sh" "$mut_dir/framework.sh"
    command cp -r "$src_dir/framework" "$mut_dir/framework"
    command sed -i 's/^tf_disable_git_signing$/:/; s/^    tf_disable_git_signing$/    :/' \
        "$mut_dir/framework.sh"
    # The mutation must actually have removed both call sites.
    calls=$(command grep -cE '^ *tf_disable_git_signing$' "$mut_dir/framework.sh" || true)
    assert_equals "0" "$calls" "mutant must contain no tf_disable_git_signing call"

    out=$(FRAMEWORK_SH="$mut_dir/framework.sh" _run_hostile yes "$COMMIT_BODY")
    assert_contains "$out" "commit_rc=fail" \
        "without the override the always-failing signer must break the scratch commit"
    assert_not_contains "$out" "hook_not_applied" "the hostile BASH_ENV hook must have applied"
}

run_test test_control_stub_signer_breaks_commit "control: failing signer breaks commit without the framework"
run_test test_framework_commit_is_unsigned "scratch commit under the framework is unsigned"
run_test test_mutation_without_override_commit_fails "mutation: framework copy without the override signs (and fails)"
run_test test_child_bash_with_bash_env_commits_unsigned "child bash re-exporting signing via BASH_ENV still commits unsigned"
run_test test_framework_annotated_tag_is_unsigned "annotated tag under the framework is unsigned"
run_test test_explicit_git_c_still_wins "explicit git -c commit.gpgsign=true still wins"
run_test test_init_reasserts_after_clear "init_test_framework restores a cleared override"
run_test test_params_set_once_and_idempotent "override set once; re-init and nested re-source are no-ops"
run_test test_existing_params_preserved "existing GIT_CONFIG_PARAMETERS preserved"
run_test test_partial_or_earlier_match_still_appends "override not last -> appended again"
run_test test_config_count_entries_untouched "GIT_CONFIG_COUNT entries untouched"
run_test test_framework_does_not_touch_git_config_files "override is env-only; operator config untouched"

generate_report
