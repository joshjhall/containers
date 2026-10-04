#!/usr/bin/env bash
# Shared harness that drives a feature script's require_cosign guard at runtime.
#
# SOURCE-ONLY: defines no tests. It lives under tests/framework/ so that
# run_unit_tests.sh (which discovers suites under tests/unit/) never runs it.
#
# Sourced by tests/unit/features/{docker,kubernetes}.sh. Both feature scripts
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
    command sed "s|/tmp/build-scripts/|$dir/build-scripts/|g" "$script" |
        command awk -v mutate="$mutate" '
            /^require_cosign \|\|/ { in_guard = 1 }
            in_guard && mutate == "--mutate" { sub(/exit 1/, ":") }
            { print }
            in_guard && /^}/ { exit }
        ' >"$dir/feature-script"
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
