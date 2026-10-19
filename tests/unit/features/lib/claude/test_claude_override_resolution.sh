#!/usr/bin/env bash
# TV / TV_DEFAULT / TV_FILE are read by name inside the resolver.
# shellcheck disable=SC2034
#
# Unit tests for component override resolution (issue #1316)
#
# CLAUDE_PLUGINS, CLAUDE_MCPS, CLAUDE_SKILLS and CLAUDE_LIBRARIAN_PLUGINS all
# resolve through _resolve_override_list in claude-plugin-lib.sh: runtime var,
# then the build-time ${var}_DEFAULT that persist-feature-flags.sh bakes in,
# then the built-in defaults. `none` is the one spelling for "no defaults" at
# both build time and runtime; an empty value means unset everywhere.
#
# A value mixing `none` with entries is refused and resolution continues at the
# NEXT tier — not straight to the built-ins (#1331). So runtime `none,foo` over
# a build-time `none` yields the empty list: the build-time opt-out still holds.
#
# The functions under test are EXTRACTED FROM PRODUCTION and eval'd, never
# mirrored by hand: a mirror keeps passing after the real resolver changes
# underneath it, which is how the pre-#1316 suite pinned the old semantics.
# Tests drive them with scratch TV / TV_DEFAULT variables, since the resolver
# reads both by name.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

init_test_framework

test_suite "claude override resolution Tests"

PLUGIN_LIB="$PROJECT_ROOT/lib/features/lib/claude/claude-plugin-lib.sh"

# Extract a column-0 `name() {` … `}` function from a file (shfmt layout).
_extract_shell_function() {
    local file="$1" name="$2"
    command awk -v name="$name" '
        $0 == name "() {" { in_fn = 1 }
        in_fn { print }
        in_fn && $0 == "}" { exit }
    ' "$file"
}

# Load a production function or abort: a silent no-op would make every test
# below pass vacuously.
_load_production_function() {
    local name="$1" src
    src=$(_extract_shell_function "$PLUGIN_LIB" "$name")
    if [ -z "$src" ]; then
        echo "FATAL: could not extract $name() from $PLUGIN_LIB" >&2
        exit 1
    fi
    eval "$src"
}

_load_production_function "_trim"
_load_production_function "_classify_override_value"
_load_production_function "_resolve_override_list"
_load_production_function "_resolve_override_list_or_file"

_RESOLVED_FROM_FILE=$(command mktemp)
_STDERR_FILE=$(command mktemp)

DEFAULTS="d1,d2"

# Results of the last _resolve call.
OUT="" RC="" ERR=""

# Run the resolver against TV, capturing stdout, return code and stderr
# separately — callers capture stdout with $(), so a warning on stdout would
# corrupt the list.
_resolve() {
    local fn="${1:-_resolve_override_list}"
    if OUT=$("$fn" "TV" "$DEFAULTS" 2>"$_STDERR_FILE"); then
        RC=0
    else
        RC=$?
    fi
    ERR=$(command cat "$_STDERR_FILE")
}

setup() {
    unset TV TV_DEFAULT TV_FILE TV_FILE_DEFAULT 2>/dev/null || true
}

# --- Unset / ordinary lists (unchanged behavior) ---

test_unset_returns_defaults() {
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_equals "d1,d2" "$OUT" "unset → built-in defaults"
    assert_equals "1" "$RC" "rc 1 when using defaults"
    assert_equals "" "$ERR" "no warning when nothing was set"
}

test_runtime_list_overrides() {
    TV="x,y"
    TV_DEFAULT="p,q"
    _resolve
    assert_equals "x,y" "$OUT" "runtime list wins over build default"
    assert_equals "0" "$RC" "rc 0 for an explicit override"
}

test_buildtime_list_overrides() {
    TV_DEFAULT="p,q"
    _resolve
    assert_equals "p,q" "$OUT" "build default wins over built-ins"
    assert_equals "0" "$RC" "rc 0 for a build-time override"
}

# --- Empty means unset ---

test_runtime_empty_is_unset_and_warns() {
    TV=""
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_equals "d1,d2" "$OUT" "runtime \"\" falls through to built-ins"
    assert_equals "1" "$RC" "rc 1: no override is active"
    assert_contains "$ERR" "TV is empty" "warning names the variable"
    assert_contains "$ERR" "TV=none" "warning points at the none spelling"
}

test_runtime_empty_falls_through_to_build_default() {
    TV=""
    TV_DEFAULT="p,q"
    _resolve
    assert_equals "p,q" "$OUT" "runtime \"\" falls through to the build default"
    assert_equals "0" "$RC" "rc 0: the build-time override is active"
}

test_runtime_whitespace_is_unset() {
    TV="   "
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_equals "d1,d2" "$OUT" "whitespace-only runtime value is unset"
    assert_contains "$ERR" "TV=none" "whitespace-only value warns like empty"
}

test_buildtime_empty_is_unset() {
    TV_DEFAULT=""
    _resolve
    assert_equals "d1,d2" "$OUT" "empty build default falls through to built-ins"
    assert_equals "1" "$RC" "rc 1: no override is active"
}

# --- none opts out ---

test_runtime_none_is_empty_list() {
    TV="none"
    TV_DEFAULT="p,q"
    _resolve
    assert_equals "" "$OUT" "runtime none → empty list, even over a build list"
    assert_equals "0" "$RC" "rc 0: explicit override active"
    assert_equals "" "$ERR" "none is a clean spelling — no warning"
}

test_runtime_none_trims_whitespace() {
    TV="  none  "
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_equals "" "$OUT" "surrounding whitespace is trimmed"
    assert_equals "0" "$RC" "rc 0"
}

test_none_is_case_sensitive() {
    TV="None"
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_equals "None" "$OUT" "None is an ordinary entry, not the opt-out"
    assert_equals "0" "$RC" "rc 0: treated as a list"
}

test_buildtime_none_is_empty_list() {
    TV_DEFAULT="none"
    _resolve
    assert_equals "" "$OUT" "build-time none → empty list"
    assert_equals "0" "$RC" "rc 0: build-time override active"
}

test_runtime_list_overrides_buildtime_none() {
    TV="x"
    TV_DEFAULT="none"
    _resolve
    assert_equals "x" "$OUT" "runtime list still beats a build-time none"
}

# --- none mixed with other entries refuses, never half-applies ---

test_runtime_mixed_none_falls_back_to_defaults() {
    TV="none,foo"
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_equals "d1,d2" "$OUT" "mixed none → built-in defaults, not 'foo'"
    assert_equals "1" "$RC" "rc 1"
    assert_contains "$ERR" "TV=none,foo" "warning names the variable and value"
}

test_runtime_mixed_none_falls_back_to_build_default() {
    TV=" foo , none "
    TV_DEFAULT="p,q"
    _resolve
    assert_equals "p,q" "$OUT" "mixed none (any order, spaced) → next tier"
    assert_contains "$ERR" "mixes 'none'" "warning explains the refusal"
}

test_buildtime_mixed_none_falls_back_to_defaults() {
    TV_DEFAULT="none,x"
    _resolve
    assert_equals "d1,d2" "$OUT" "mixed build-time none → built-ins"
    assert_contains "$ERR" "TV_DEFAULT=none,x" "warning names the _DEFAULT var"
}

# The fallback is to the NEXT tier, so a mixed runtime value over a build-time
# `none` lands on that `none` — never on the built-ins (#1331).
test_runtime_mixed_none_over_buildtime_none_is_empty() {
    TV="none,foo"
    TV_DEFAULT="none"
    _resolve
    assert_equals "" "$OUT" "mixed runtime none → build-time none → empty list"
    assert_equals "0" "$RC" "rc 0: the build-time opt-out is active"
    assert_contains "$ERR" "TV=none,foo" "the refused runtime value still warns"
}

test_runtime_spaced_mixed_none_falls_back_to_defaults() {
    TV=" none , plugin-a "
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_equals "d1,d2" "$OUT" "spaced mixed none → built-in defaults"
    assert_equals "1" "$RC" "rc 1"
    assert_contains "$ERR" "mixes 'none'" "spaced mixed value warns"
}

# --- none beside only empty items is still none ---

test_runtime_none_trailing_comma_is_none() {
    TV="none,"
    TV_DEFAULT="p,q"
    _resolve
    assert_equals "" "$OUT" "none, → empty list, not the build default"
    assert_equals "0" "$RC" "rc 0: explicit override active"
    assert_equals "" "$ERR" "empty items are not 'other entries' — no warning"
}

test_runtime_none_leading_comma_is_none() {
    TV=" , none"
    TV_DEFAULT="p,q"
    _resolve
    assert_equals "" "$OUT" ", none → empty list"
    assert_equals "0" "$RC" "rc 0"
    assert_equals "" "$ERR" "no warning"
}

# --- stdout carries only the list ---

test_warnings_never_reach_stdout() {
    TV=""
    TV_DEFAULT="__UNSET__"
    _resolve
    assert_not_contains "$OUT" "⚠" "warning text stays off stdout"
}

# --- _FILE path inherits the semantics ---

test_file_empty_array_means_no_defaults() {
    local tmpfile
    tmpfile=$(command mktemp)
    echo '[]' >"$tmpfile"
    TV_FILE="$tmpfile"
    TV_DEFAULT="__UNSET__"
    _resolve _resolve_override_list_or_file
    assert_equals "[]" "$OUT" "a [] file resolves to an empty array"
    assert_equals "0" "$RC" "rc 0: file override active"
    assert_equals "file" "$(command cat "$_RESOLVED_FROM_FILE")" "resolved from file"
    command rm -f "$tmpfile"
}

test_file_path_falls_through_to_none() {
    TV="none"
    TV_DEFAULT="__UNSET__"
    _resolve _resolve_override_list_or_file
    assert_equals "" "$OUT" "no file → env none → empty list"
    assert_equals "0" "$RC" "rc 0"
    assert_equals "env" "$(command cat "$_RESOLVED_FROM_FILE")" "resolved from env"
}

test_file_path_falls_through_on_empty() {
    TV=""
    TV_DEFAULT="__UNSET__"
    _resolve _resolve_override_list_or_file
    assert_equals "d1,d2" "$OUT" "no file → env \"\" → built-in defaults"
    assert_equals "default" "$(command cat "$_RESOLVED_FROM_FILE")" "resolved from defaults"
}

run_test test_unset_returns_defaults "Resolve: unset returns defaults"
run_test test_runtime_list_overrides "Resolve: runtime list overrides"
run_test test_buildtime_list_overrides "Resolve: build-time list overrides"
run_test test_runtime_empty_is_unset_and_warns "Resolve: runtime empty is unset + warns"
run_test test_runtime_empty_falls_through_to_build_default "Resolve: runtime empty → build default"
run_test test_runtime_whitespace_is_unset "Resolve: whitespace-only runtime is unset"
run_test test_buildtime_empty_is_unset "Resolve: build-time empty is unset"
run_test test_runtime_none_is_empty_list "Resolve: runtime none → empty"
run_test test_runtime_none_trims_whitespace "Resolve: spaced none → empty"
run_test test_none_is_case_sensitive "Resolve: None is case-sensitive"
run_test test_buildtime_none_is_empty_list "Resolve: build-time none → empty"
run_test test_runtime_list_overrides_buildtime_none "Resolve: runtime list beats build none"
run_test test_runtime_mixed_none_falls_back_to_defaults "Resolve: mixed none → defaults"
run_test test_runtime_mixed_none_falls_back_to_build_default "Resolve: mixed none → build default"
run_test test_buildtime_mixed_none_falls_back_to_defaults "Resolve: mixed build none → defaults"
run_test test_runtime_mixed_none_over_buildtime_none_is_empty "Resolve: mixed none → build none → empty"
run_test test_runtime_spaced_mixed_none_falls_back_to_defaults "Resolve: spaced mixed none → defaults"
run_test test_runtime_none_trailing_comma_is_none "Resolve: none, is none"
run_test test_runtime_none_leading_comma_is_none "Resolve: , none is none"
run_test test_warnings_never_reach_stdout "Resolve: warnings stay on stderr"
run_test test_file_empty_array_means_no_defaults "File: [] means no defaults"
run_test test_file_path_falls_through_to_none "File: falls through to none"
run_test test_file_path_falls_through_on_empty "File: falls through on empty"

command rm -f "$_RESOLVED_FROM_FILE" "$_STDERR_FILE"

# Generate test report. Deliberately the LAST command: a suite's exit status is
# its final command's.
generate_report
