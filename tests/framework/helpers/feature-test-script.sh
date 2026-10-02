#!/usr/bin/env bash
# Shared harness for a feature's installed `test-<x>` verification script.
#
# SOURCE-ONLY: defines no tests. It lives under tests/framework/ so that
# run_unit_tests.sh (which discovers suites under tests/unit/) never runs it.
#
# Sourced by tests/unit/features/{python-dev,ruby-dev,rust}.sh. Runs a
# lib/features/lib/**/test-*.sh script against a PATH holding only stub
# executables for the tools named, the way it would run in an image built with
# exactly those tools (#1001).

# run_feature_test_script <script> <check_lsp> <tool>...
#
# <check_lsp> substitutes the __CHECK_LSP__ placeholder ("true"/"false"; pass
# "keep" to leave it unsubstituted). Each <tool> becomes a no-op stub on PATH.
# Prints the script's output followed by a final "rc=<exit status>" line.
run_feature_test_script() {
    local script="$1" check_lsp="$2"
    shift 2
    local dir tool rc=0
    # A missing script must not run as an empty file and "exit 0": report a
    # status no assertion expects, so both the pass and fail cases fail.
    if [ ! -f "$script" ]; then
        command printf 'missing script: %s\nrc=missing\n' "$script"
        return 0
    fi
    dir=$(command mktemp -d)
    command mkdir -p "$dir/bin"
    for tool in "$@"; do
        command printf '#!/bin/sh\necho "%s 0.0.0"\n' "$tool" >"$dir/bin/$tool"
        command chmod +x "$dir/bin/$tool"
    done
    if [ "$check_lsp" = "keep" ]; then
        command cp "$script" "$dir/test-script"
    else
        command sed "s/__CHECK_LSP__/${check_lsp}/" "$script" >"$dir/test-script"
    fi
    # Only the stubs on PATH, plus the coreutils the script itself calls, so a
    # tool installed on the test host can never satisfy a check. Resolve head
    # from the host rather than assuming /usr/bin, and fail loudly without it:
    # a dangling link would make the script fail for an unrelated reason.
    local head_bin
    head_bin=$(command -v head) || head_bin=""
    if [ -z "$head_bin" ]; then
        command printf 'harness error: head not found on PATH\nrc=harness-error\n'
        command rm -rf "$dir"
        return 0
    fi
    command ln -s "$head_bin" "$dir/bin/head"
    BASH_ENV="" PATH="$dir/bin" /bin/bash "$dir/test-script" 2>&1 || rc=$?
    command printf 'rc=%s\n' "$rc"
    command rm -rf "$dir"
}
