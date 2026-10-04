#!/usr/bin/env bash
# Shared harness that drives a feature script's require_cosign guard at runtime.
#
# SOURCE-ONLY: defines test functions but runs none until a suite calls
# register_cosign_guard_tests. It lives under tests/framework/ so that
# run_unit_tests.sh (which discovers suites under tests/unit/) never runs it.
#
# Sourced by tests/unit/features/{docker,kubernetes}.sh, which call
# register_cosign_guard_tests. Both feature scripts
# end their cosign section with
#
#     require_cosign || {
#         log_feature_end
#         exit 1
#     }
#
# and a static grep only proves that text is written (#941). This runs the real
# script as a process — under its own `set -euo pipefail` — and reports its
# exit status, so a refactor that swallows the exit is caught.
#
# How the build-time environment is faked:
#   - /tmp/build-scripts/ is rewritten to a sandbox holding empty stubs for the
#     sourced helpers, except cosign-require.sh, which is the REAL file.
#   - The stub feature-header.sh defines log_message/log_error/log_warning to
#     echo, so the guard's messages reach the output for assertions.
#   - PATH holds only the sandbox bin dir, and command_not_found_handle turns
#     every other external tool and unstubbed helper (apt_install, curl, gpg,
#     verify_download_or_fail, ...) into a successful no-op that drains its
#     stdin — a stub that never reads would SIGPIPE the writer of an
#     `echo ... | tee` pipeline under pipefail. The build steps
#     before the guard therefore run inert: no network, no root, no writes.
#     This holds only while those steps invoke tools by bare name (or via
#     `command`): a command written as an absolute path (/usr/bin/curl) is not
#     a lookup and would run for real, so keep that out of the pre-guard code.
#   - The copy is truncated after the guard's closing brace and ends with
#     `echo PAST_GUARD; exit 0`, so nothing after the guard runs on the host.

# run_feature_cosign_guard <feature-script> <mode> [--mutate]
#
# <mode>:
#   absent   — no cosign on PATH (the base install did not happen)
#   shadowed — a cosign on PATH that is not the base install (#940)
#   present  — a cosign on PATH that the copied guard accepts as the base
#              install; the positive control that the harness reaches and
#              passes the guard
# --mutate replaces the guard's `exit 1` with a no-op `:` in the scratch copy —
# the mutant a discriminating test must reject. Production files are never
# edited.
#
# Prints the script's output followed by a final "rc=<exit status>" line.
run_feature_cosign_guard() {
    local script="$1" mode="$2" mutate="${3:-}"
    local dir rc=0 helper
    # A missing script must not run as an empty file: report a status no
    # assertion expects, so both the pass and fail cases fail.
    if [ ! -f "$script" ]; then
        command printf 'missing script: %s\nrc=missing\n' "$script"
        return 0
    fi
    # Without the guard there is nothing to truncate at, and running the whole
    # script on the test host is not an option.
    if ! command grep -q '^require_cosign ||' "$script"; then
        command printf 'guard not found in: %s\nrc=missing\n' "$script"
        return 0
    fi
    dir=$(command mktemp -d)
    command mkdir -p "$dir/bin" "$dir/build-scripts/base"

    for helper in feature-header apt-utils retry-utils checksum-fetch \
        download-verify checksum-verification cache-utils path-utils; do
        : >"$dir/build-scripts/base/$helper.sh"
    done
    command cat >"$dir/build-scripts/base/feature-header.sh" <<'STUB'
log_message() { echo "$*"; }
log_error() { echo "ERROR: $*"; }
log_warning() { echo "WARNING: $*"; }
STUB

    # The real guard, with its build-scripts paths pointed at the sandbox. In
    # "present" mode the pinned base path is widened to the stub, which is the
    # only way a test host can satisfy it.
    command sed "s|/tmp/build-scripts/|$dir/build-scripts/|g" \
        "$PROJECT_ROOT/lib/base/cosign-require.sh" >"$dir/build-scripts/base/cosign-require.sh"
    if [ "$mode" = "present" ]; then
        command sed -i "s|^_COSIGN_BASE_PATH=.*|_COSIGN_BASE_PATH=\"$dir/bin/cosign\"|" \
            "$dir/build-scripts/base/cosign-require.sh"
    fi

    if [ "$mode" = "present" ] || [ "$mode" = "shadowed" ]; then
        command printf '#!/bin/sh\necho "cosign 0.0.0"\n' >"$dir/bin/cosign"
        command chmod +x "$dir/bin/cosign"
    fi
    # kubernetes.sh verifies k9s and helm with `command -v` and exits 1 before
    # the cosign section if either is missing.
    for helper in k9s helm; do
        command printf '#!/bin/sh\necho "%s 0.0.0"\n' "$helper" >"$dir/bin/$helper"
        command chmod +x "$dir/bin/$helper"
    done

    # Copy up to the guard's closing brace (the first column-0 `}` after
    # `require_cosign ||`), optionally no-op its exit, then mark the far side.
    # awk stops printing rather than exiting: an early exit would close the
    # pipe on a still-writing sed, and SIGPIPE fails the caller's pipefail.
    command sed "s|/tmp/build-scripts/|$dir/build-scripts/|g" "$script" |
        command awk -v mutate="$mutate" '
            done { next }
            /^require_cosign \|\|/ { in_guard = 1 }
            in_guard && mutate == "--mutate" { sub(/exit 1/, ":") }
            { print }
            in_guard && /^}/ { done = 1 }
            END { exit !done }
        ' >"$dir/feature-script" || {
        # No column-0 `}` closed the guard (a one-line `require_cosign ||
        # exit 1`, or an indented brace): the copy would run the whole script
        # on the host. Refuse, with a status no assertion expects.
        command printf 'guard not truncatable in: %s\nrc=missing\n' "$script"
        command rm -rf "$dir"
        return 0
    }
    echo 'echo PAST_GUARD; exit 0' >>"$dir/feature-script"

    # shellcheck disable=SC2016 # expanded by the inner bash, not here
    BASH_ENV="" PATH="$dir/bin" USERNAME="testuser" /bin/bash -c '
        command_not_found_handle() {
            local _line
            while IFS= read -r _line; do :; done
            return 0
        }
        source "$1"
    ' feature-script "$dir/feature-script" </dev/null 2>&1 || rc=$?
    command printf 'rc=%s\n' "$rc"
    command rm -rf "$dir"
}

# Last line of run_feature_cosign_guard output is "rc=<exit status>".
_cosign_guard_rc() {
    command printf '%s\n' "$1" | command tail -n 1
}

# The runtime tests, against $COSIGN_GUARD_SCRIPT. The --mutate case
# no-ops the guard's `exit 1` in a scratch copy: if the absent-cosign test
# could pass against that mutant it would not be testing the exit path.
test_cosign_absent_exits_feature() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" absent)
    assert_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "$name exits 1 when cosign is absent"
    assert_contains "$out" "cosign not found on PATH" \
        "the exit comes from the cosign guard, not an earlier failure"
    assert_not_contains "$out" "PAST_GUARD" \
        "$name does not continue past the cosign guard"
}

test_cosign_shadowed_exits_feature() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" shadowed)
    assert_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "$name exits 1 when a non-base cosign shadows the base install"
    assert_contains "$out" "not the base install" \
        "the exit comes from the #940 resolved-path check"
    assert_not_contains "$out" "PAST_GUARD" \
        "$name does not continue past the cosign guard"
}

test_cosign_present_passes_guard() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" present)
    assert_equals "rc=0" "$(_cosign_guard_rc "$out")" \
        "$name runs through the guard when the base cosign is present"
    assert_contains "$out" "PAST_GUARD" \
        "harness reaches the far side of the guard (positive control)"
}

test_cosign_guard_mutant_is_detected() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" absent --mutate)
    assert_contains "$out" "PAST_GUARD" \
        "with the guard's exit no-op'd, $name continues past it"
    assert_not_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "the absent-cosign exit status discriminates the mutant"
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" shadowed --mutate)
    assert_contains "$out" "PAST_GUARD" \
        "with the guard's exit no-op'd, a shadowed cosign also continues past it"
    assert_not_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "the shadowed-cosign exit status discriminates the mutant"
}

# A guard the truncation cannot find the end of must be refused, not run: the
# copy would otherwise be the whole feature script. Drives the refusal with a
# scratch copy whose guard is collapsed to one line.
test_cosign_guard_untruncatable_is_refused() {
    local out scratch
    scratch=$(command mktemp)
    command awk '
        /^require_cosign \|\|/ { print "require_cosign || exit 1"; skip = 1; next }
        skip && /^}/ { skip = 0; next }
        !skip { print }
    ' "$COSIGN_GUARD_SCRIPT" >"$scratch"
    out=$(run_feature_cosign_guard "$scratch" absent)
    command rm -f "$scratch"
    assert_equals "rc=missing" "$(_cosign_guard_rc "$out")" \
        "a one-line guard is refused rather than run to the end of the script"
    assert_contains "$out" "guard not truncatable" \
        "the refusal names the truncation, not a missing guard"
}

# register_cosign_guard_tests <feature-script>
#
# Runs the tests above against <feature-script> in the calling suite.
register_cosign_guard_tests() {
    COSIGN_GUARD_SCRIPT="$1"
    run_test test_cosign_absent_exits_feature "Cosign absent: feature exits 1"
    run_test test_cosign_shadowed_exits_feature "Cosign shadowed: feature exits 1"
    run_test test_cosign_present_passes_guard "Cosign present: feature passes guard"
    run_test test_cosign_guard_mutant_is_detected "Cosign guard mutant detected"
    run_test test_cosign_guard_untruncatable_is_refused "Cosign guard: untruncatable copy refused"
}
