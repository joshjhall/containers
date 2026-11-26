#!/usr/bin/env bash
# Regression test for issue #1789: the test framework must turn commit/tag
# signing off for every git operation a unit test runs.
#
# The devcontainer injects commit.gpgsign=true / tag.gpgsign=true /
# gpg.ssh.program through GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n /
# GIT_CONFIG_VALUE_n, so scratch-repo commits signed through the operator's key
# and failed intermittently under the parallel pre-push run. framework.sh now
# appends signing-off entries to that env config.
#
# Each case runs in a CHILD shell under `env -i` with a hostile signing env whose
# gpg.ssh.program is a stub that always exits 1. A control case proves the stub
# really breaks signing without the framework, so the "unsigned" cases cannot
# pass because the stub happened to be inert.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

# Overridable so the guard can be mutation-checked against a scratch copy of
# the framework without touching the tracked file.
FRAMEWORK_SH="${SIGNING_TEST_FRAMEWORK_SH:-$SCRIPT_DIR/../framework.sh}"

test_suite "test framework disables git signing (#1789)"

# Number of hostile GIT_CONFIG_* entries injected below.
HOSTILE_COUNT=6

# Build the always-failing signer and a scratch HOME/global config.
_prepare_hostile() {
    command mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/home"
    command printf '#!/bin/sh\necho "stub signer refused" >&2\nexit 1\n' \
        >"$TEST_TEMP_DIR/bin/failing-signer"
    command chmod +x "$TEST_TEMP_DIR/bin/failing-signer"
    command printf '[core]\n\tautocrlf = false\n' >"$TEST_TEMP_DIR/home/.gitconfig"
}

# Run $2 in a fresh bash with the hostile signing env. $1=yes sources the
# framework (and runs init_test_framework) first; $1=no runs the body bare.
_run_hostile() {
    local with_framework="$1" body="$2" prelude=''
    if [ "$with_framework" = yes ]; then
        prelude='source "$FRAMEWORK_SH" >/dev/null 2>&1; init_test_framework >/dev/null 2>&1; '
    fi
    /usr/bin/env -i \
        PATH="/usr/bin:/bin" \
        HOME="$TEST_TEMP_DIR/home" \
        TERM="dumb" \
        SKIP_DOCKER_CHECK=true \
        FRAMEWORK_SH="$FRAMEWORK_SH" \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL="$TEST_TEMP_DIR/home/.gitconfig" \
        GIT_CONFIG_COUNT="$HOSTILE_COUNT" \
        GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0="Test User" \
        GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1="test@example.com" \
        GIT_CONFIG_KEY_2=gpg.format GIT_CONFIG_VALUE_2=ssh \
        GIT_CONFIG_KEY_3=gpg.ssh.program GIT_CONFIG_VALUE_3="$TEST_TEMP_DIR/bin/failing-signer" \
        GIT_CONFIG_KEY_4=commit.gpgsign GIT_CONFIG_VALUE_4=true \
        GIT_CONFIG_KEY_5=tag.gpgsign GIT_CONFIG_VALUE_5=true \
        REPO="$TEST_TEMP_DIR/repo" \
        /bin/bash -c "${prelude}${body}"
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
    out=$(_run_hostile no "$COMMIT_BODY")
    assert_equals "commit_rc=fail" "$out" \
        "without the framework the always-failing signer must break git commit"
}

test_framework_commit_is_unsigned() {
    _prepare_hostile
    local out
    out=$(_run_hostile yes "$COMMIT_BODY")
    assert_contains "$out" "commit_rc=0" "scratch commit must succeed under the framework"
    assert_contains "$out" "gpgsig=absent" "scratch commit must carry no gpgsig header"
    assert_not_contains "$out" "gpgsig=present" "scratch commit must not be signed"
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

# Existing entries survive untouched; exactly two are appended, and repeated
# re-application (init_test_framework + a direct call, as a re-initialising
# consumer would do) does not grow the count further. Re-sourcing in-process is
# not possible (readonly vars), so a nested child shell covers that path below.
test_framework_appends_and_preserves() {
    _prepare_hostile
    local out
    out=$(_run_hostile yes '
        init_test_framework >/dev/null 2>&1
        tf_disable_git_signing
        /usr/bin/echo "nested_$(/bin/bash -c '\''source "$FRAMEWORK_SH" >/dev/null 2>&1; /usr/bin/echo "count=$GIT_CONFIG_COUNT"'\'')"
        /usr/bin/echo "count=$GIT_CONFIG_COUNT"
        i=0
        while [ "$i" -lt "$GIT_CONFIG_COUNT" ]; do
            k="GIT_CONFIG_KEY_$i"; v="GIT_CONFIG_VALUE_$i"
            /usr/bin/echo "entry$i=${!k}=${!v}"
            i=$((i + 1))
        done
    ')
    assert_contains "$out" $'\n'"count=$((HOSTILE_COUNT + 2))" \
        "exactly two entries appended, even after re-init + direct re-apply"
    assert_contains "$out" "nested_count=$((HOSTILE_COUNT + 2))" \
        "a child shell re-sourcing the framework must not append again"
    assert_contains "$out" "entry0=user.name=Test User" "entry 0 preserved"
    assert_contains "$out" "entry3=gpg.ssh.program=$TEST_TEMP_DIR/bin/failing-signer" "entry 3 preserved"
    assert_contains "$out" "entry4=commit.gpgsign=true" "injected commit.gpgsign entry preserved"
    assert_contains "$out" "entry5=tag.gpgsign=true" "injected tag.gpgsign entry preserved"
    assert_contains "$out" "entry6=commit.gpgsign=false" "commit.gpgsign=false appended last-but-one"
    assert_contains "$out" "entry7=tag.gpgsign=false" "tag.gpgsign=false appended last"
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

# A non-numeric count must not propagate into a value that breaks every git call.
test_framework_recovers_from_bogus_count() {
    _prepare_hostile
    local out
    out=$(/usr/bin/env -i PATH="/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" \
        SKIP_DOCKER_CHECK=true FRAMEWORK_SH="$FRAMEWORK_SH" GIT_CONFIG_COUNT=bogus \
        /bin/bash -c 'source "$FRAMEWORK_SH" >/dev/null 2>&1; /usr/bin/echo "count=$GIT_CONFIG_COUNT ${GIT_CONFIG_KEY_0}=${GIT_CONFIG_VALUE_0}"')
    assert_equals "count=2 commit.gpgsign=false" "$out" "bogus count restarts at 0"
}

run_test test_control_stub_signer_breaks_commit "control: failing signer breaks commit without the framework"
run_test test_framework_commit_is_unsigned "scratch commit under the framework is unsigned"
run_test test_framework_annotated_tag_is_unsigned "annotated tag under the framework is unsigned"
run_test test_framework_appends_and_preserves "signing-off entries appended once, existing entries preserved"
run_test test_framework_does_not_touch_git_config_files "override is env-only; operator config untouched"
run_test test_framework_recovers_from_bogus_count "non-numeric GIT_CONFIG_COUNT restarts at 0"

generate_report
