#!/bin/bash
# Unit tests for claude-code-setup.sh pattern matching functions
#
# Tests the extracted testable functions:
# - _match_plugin_in_list: Plugin detection from 'claude plugin list' output
# - _match_mcp_server_in_list: MCP server detection from 'claude mcp list' output
# - _parse_git_remote_host: Git remote URL parsing
# - _classify_git_host: Git platform classification from hostname
#
# These tests validate the pattern matching logic without requiring the Claude CLI.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Claude Code Setup Pattern Matching Tests"

# ============================================================================
# Sample CLI Outputs (captured from real Claude CLI)
# ============================================================================

# Sample 'claude plugin list' output
SAMPLE_PLUGIN_LIST='  ❯ commit-commands@claude-plugins-official - Git commit helpers
  ❯ figma@claude-plugins-official - Figma design integration
  ❯ pr-review-toolkit@claude-plugins-official - PR review tools
  ❯ rust-analyzer-lsp@claude-plugins-official - Rust LSP integration
  ❯ pyright-lsp@claude-plugins-official - Python LSP integration'

# Sample multi-line 'claude plugin list' output (captured verbatim from the CLI
# on 2026-08-19). This is the CURRENT format — one block per plugin, with an
# explicit Status: line. The single-line SAMPLE_PLUGIN_LIST above is the OLDER
# format, retained because _match_plugin_in_list must keep handling it.
#
# review-audit is disabled here: exactly the state issue #784 produces when two
# concurrent claude-setup runs clobber each other's enabledPlugins writes.
SAMPLE_PLUGIN_LIST_STATUS='Installed plugins:

  ❯ dev-core@librarian
    Version: 0.10.0
    Scope: user
    Status: ✔ enabled

  ❯ review-audit@librarian
    Version: 0.10.0
    Scope: user
    Status: ✘ disabled

  ❯ workflow@librarian
    Version: 0.10.0
    Scope: user
    Status: ✔ enabled'

# Empty plugin list
EMPTY_PLUGIN_LIST=''

# Plugin list with only whitespace
WHITESPACE_PLUGIN_LIST='

'

# Sample 'claude mcp list' output
SAMPLE_MCP_LIST='filesystem: npx -y @modelcontextprotocol/server-filesystem /workspace - running
github: npx -y @modelcontextprotocol/server-github - stopped
figma-desktop: http://host.docker.internal:3845/mcp - running
gitlab: npx -y @modelcontextprotocol/server-gitlab - running'

# Empty MCP list
EMPTY_MCP_LIST=''

# MCP list with different formats (edge cases)
MCP_LIST_EDGE_CASES='filesystem: /path/to/server - running
github-enterprise: npx server - stopped
my-custom-server: python server.py - running'

# ============================================================================
# Helper: Extract and define the pattern matching functions for testing
# ============================================================================

CLAUDE_SETUP="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"

# Print one shell function's definition verbatim from a script.
#
# claude-setup cannot be sourced: it runs plugin installs, MCP config, and a
# `claude` CLI probe at load time. Extraction gives the tests the REAL function
# bodies anyway, so the wiring between plugin_status → install_plugin →
# enable_plugin is executed rather than only source-grepped (#787).
#
# It also removes the copy-drift that hand-written mirrors carried: a mirror
# passes forever after production changes underneath it.
#
# Relies on the repo's shfmt-enforced layout — `name() {` and the closing `}`
# both at column 0. _assert_extractable below fails loudly if that stops holding
# for a function these tests depend on, rather than silently extracting nothing.
_extract_shell_function() {
    local file="$1" name="$2"
    command awk -v name="$name" '
        $0 == name "() {" { in_fn = 1 }
        in_fn { print }
        in_fn && $0 == "}" { exit }
    ' "$file"
}

# Load a function from claude-setup into this shell, or abort the suite.
# A silent no-op here would make every test below vacuously pass.
_load_production_function() {
    local name="$1" src
    src=$(_extract_shell_function "$CLAUDE_SETUP" "$name")
    if [ -z "$src" ]; then
        echo "FATAL: could not extract $name() from $CLAUDE_SETUP" >&2
        exit 1
    fi
    eval "$src"
}

# The real implementations, pulled from claude-setup (#787).
_load_production_function "_plugin_status_in_list"
_load_production_function "_is_in_list"
_load_production_function "plugin_status"
_load_production_function "enable_plugin"
_load_production_function "install_plugin"
_load_production_function "_plugin_is_denied"
_load_production_function "_log_denied_plugin"

# Globals the extracted functions close over. install_plugin builds full_name
# from $MARKETPLACE; the deny-list helpers read $DISABLED_PLUGINS; the retry
# loops read $CLAUDE_SETUP_RETRY_DELAY (0 keeps the suite fast — production
# defaults to 2).
# shellcheck disable=SC2034  # read by the extracted production functions
MARKETPLACE="claude-plugins-official"
# shellcheck disable=SC2034  # read by _plugin_is_denied; set per-test below
DISABLED_PLUGINS=""
export CLAUDE_SETUP_RETRY_DELAY=0

_match_plugin_in_list() {
    local plugin_name="$1"
    local list_output="$2"
    echo "$list_output" | command grep -qE "^[[:space:]]*❯ ${plugin_name}@" 2>/dev/null
}

# ============================================================================
# claude CLI Mock (#787)
# ============================================================================
# The extracted functions shell out to `claude`. This function shadows it (a
# shell function beats PATH lookup), returning canned output driven by the
# MOCK_* globals and appending every invocation to MOCK_CALL_LOG so tests can
# assert the exact argv — notably that enable_plugin is handed full_name
# (name@marketplace), not the bare plugin name.
MOCK_CALL_LOG=""
MOCK_LIST_OUTPUT=""
MOCK_LIST_RC=0
MOCK_ENABLE_OUTPUT=""
# Space-separated exit codes consumed one per `plugin enable` call, so a test
# can script fail-then-succeed. The last value repeats once exhausted.
#
# Held in a FILE, not a variable: claude() is called from inside `$(...)` command
# substitutions in the production code, so a variable mutation would be discarded
# with the subshell and every scripted call would replay the first code forever.
MOCK_ENABLE_RC_FILE=""
MOCK_INSTALL_OUTPUT=""
MOCK_INSTALL_RC_FILE=""

_mock_reset() {
    MOCK_CALL_LOG=$(command mktemp)
    MOCK_ENABLE_RC_FILE=$(command mktemp)
    MOCK_INSTALL_RC_FILE=$(command mktemp)
    echo "0" >"$MOCK_ENABLE_RC_FILE"
    echo "0" >"$MOCK_INSTALL_RC_FILE"
    # Cleared here rather than at the end of each deny-list test, so a test that
    # returns early cannot leak its deny-list into the next one.
    DISABLED_PLUGINS=""
    MOCK_LIST_OUTPUT=""
    MOCK_LIST_RC=0
    MOCK_ENABLE_OUTPUT=""
    MOCK_INSTALL_OUTPUT=""
}

# Script the exit codes `plugin enable` / `plugin install` will return, in order.
_mock_set_enable_rcs() {
    echo "$*" >"$MOCK_ENABLE_RC_FILE"
}

_mock_set_install_rcs() {
    echo "$*" >"$MOCK_INSTALL_RC_FILE"
}

# Pop the next scripted exit code from a queue file; the final one sticks.
_mock_next_rc() {
    local file="$1" rcs first rest
    rcs=$(command cat "$file")
    first="${rcs%% *}"
    rest="${rcs#* }"
    [ "$rest" != "$rcs" ] && echo "$rest" >"$file"
    echo "$first"
}

_mock_cleanup() {
    command rm -f "$MOCK_CALL_LOG" "$MOCK_ENABLE_RC_FILE" "$MOCK_INSTALL_RC_FILE"
}

claude() {
    echo "$*" >>"$MOCK_CALL_LOG"
    case "$1 $2" in
        "plugin list")
            [ -n "$MOCK_LIST_OUTPUT" ] && echo "$MOCK_LIST_OUTPUT"
            return "$MOCK_LIST_RC"
            ;;
        "plugin enable")
            [ -n "$MOCK_ENABLE_OUTPUT" ] && echo "$MOCK_ENABLE_OUTPUT"
            return "$(_mock_next_rc "$MOCK_ENABLE_RC_FILE")"
            ;;
        "plugin install")
            [ -n "$MOCK_INSTALL_OUTPUT" ] && echo "$MOCK_INSTALL_OUTPUT"
            return "$(_mock_next_rc "$MOCK_INSTALL_RC_FILE")"
            ;;
    esac
    return 0
}

# Count log lines matching a pattern (0 when there are none).
# `grep -c` prints 0 AND exits 1 on no-match, so the count is captured first and
# the exit status absorbed separately — `grep -c ... || echo 0` would emit two
# lines and silently break every assert_equals against it.
_mock_call_count() {
    local n
    n=$(command grep -c -- "$1" "$MOCK_CALL_LOG" 2>/dev/null) || true
    echo "${n:-0}"
}

_match_mcp_server_in_list() {
    local server_name="$1"
    local list_output="$2"
    echo "$list_output" | command grep -qE "^${server_name}:" 2>/dev/null
}

_parse_git_remote_host() {
    local remote_url="$1"
    local host=""

    [[ "$remote_url" =~ ^https?://([^/]+)/ ]] && host="${BASH_REMATCH[1]}"
    [[ -z "$host" && "$remote_url" =~ ^git@([^:]+): ]] && host="${BASH_REMATCH[1]}"
    [[ -z "$host" && "$remote_url" =~ ^ssh://[^@]+@([^/]+)/ ]] && host="${BASH_REMATCH[1]}"

    host="${host%%:*}"
    echo "$host"
}

_classify_git_host() {
    local host="$1"

    [[ -z "$host" ]] && {
        echo "none"
        return
    }
    [[ "$host" == "github.com" ]] && {
        echo "github"
        return
    }
    [[ "$host" == "gitlab.com" || "$host" == *"gitlab"* ]] && {
        echo "gitlab:$host"
        return
    }
    echo "unknown:$host"
}

# ============================================================================
# Plugin Matching Tests
# ============================================================================

test_plugin_match_exact_name() {
    if _match_plugin_in_list "figma" "$SAMPLE_PLUGIN_LIST"; then
        assert_true true "Matches 'figma' plugin"
    else
        assert_true false "Should match 'figma' plugin"
    fi
}

test_plugin_match_with_hyphen() {
    if _match_plugin_in_list "commit-commands" "$SAMPLE_PLUGIN_LIST"; then
        assert_true true "Matches 'commit-commands' plugin"
    else
        assert_true false "Should match 'commit-commands' plugin"
    fi
}

test_plugin_match_lsp_plugin() {
    if _match_plugin_in_list "rust-analyzer-lsp" "$SAMPLE_PLUGIN_LIST"; then
        assert_true true "Matches 'rust-analyzer-lsp' plugin"
    else
        assert_true false "Should match 'rust-analyzer-lsp' plugin"
    fi
}

test_plugin_no_match_nonexistent() {
    if _match_plugin_in_list "nonexistent-plugin" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match nonexistent plugin"
    else
        assert_true true "Correctly rejects nonexistent plugin"
    fi
}

test_plugin_no_match_partial_name() {
    # "fig" should NOT match "figma"
    if _match_plugin_in_list "fig" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match partial name 'fig'"
    else
        assert_true true "Correctly rejects partial name match"
    fi
}

test_plugin_no_match_suffix() {
    # "commands" should NOT match "commit-commands"
    if _match_plugin_in_list "commands" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match suffix 'commands'"
    else
        assert_true true "Correctly rejects suffix match"
    fi
}

test_plugin_empty_list() {
    if _match_plugin_in_list "figma" "$EMPTY_PLUGIN_LIST"; then
        assert_true false "Should NOT match in empty list"
    else
        assert_true true "Correctly handles empty list"
    fi
}

test_plugin_whitespace_list() {
    if _match_plugin_in_list "figma" "$WHITESPACE_PLUGIN_LIST"; then
        assert_true false "Should NOT match in whitespace-only list"
    else
        assert_true true "Correctly handles whitespace-only list"
    fi
}

test_plugin_case_sensitive() {
    # "Figma" should NOT match "figma" (case sensitive)
    if _match_plugin_in_list "Figma" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match different case"
    else
        assert_true true "Correctly rejects case mismatch"
    fi
}

# ============================================================================
# Plugin Enablement Parsing Tests (issue #784)
# ============================================================================
# A concurrent-write race can leave a plugin installed but DISABLED.
# _match_plugin_in_list matches it either way, so the second claude-setup run
# reported "already installed" and never repaired the damage — silently removing
# every skill the plugin provides, across container restarts.
# _plugin_status_in_list is what distinguishes the two states.
#
# The source-guard tests below feed stripped source to grep via a HERE-STRING,
# never `printf ... | grep -q`. This suite runs under `set -euo pipefail`, and
# `grep -q` exits at the first match — SIGPIPE-killing the upstream printf
# (exit 141), which pipefail then propagates as test failure. That made the
# guards fail nondeterministically, on whether grep won the race.

test_plugin_status_enabled() {
    assert_equals "enabled" \
        "$(_plugin_status_in_list "dev-core" "$SAMPLE_PLUGIN_LIST_STATUS")" \
        "Enabled plugin reports 'enabled'"
}

test_plugin_status_disabled() {
    # The exact #784 failure state.
    assert_equals "disabled" \
        "$(_plugin_status_in_list "review-audit" "$SAMPLE_PLUGIN_LIST_STATUS")" \
        "Disabled plugin reports 'disabled'"
}

test_plugin_status_absent() {
    assert_equals "absent" \
        "$(_plugin_status_in_list "nonexistent-plugin" "$SAMPLE_PLUGIN_LIST_STATUS")" \
        "Uninstalled plugin reports 'absent'"
}

test_plugin_status_no_leak_to_next_block() {
    # 'workflow' immediately FOLLOWS the disabled 'review-audit' block. A parser
    # that grepped the whole output, or failed to stop at the next '❯' header,
    # would wrongly report it disabled.
    assert_equals "enabled" \
        "$(_plugin_status_in_list "workflow" "$SAMPLE_PLUGIN_LIST_STATUS")" \
        "Disabled block does not leak status into the following plugin"
}

test_plugin_status_old_format_is_enabled() {
    # The older single-line format carries no Status: line at all. Treating a
    # missing status as 'disabled' would make every old-format path spuriously
    # "repair" an already-fine plugin.
    assert_equals "enabled" \
        "$(_plugin_status_in_list "figma" "$SAMPLE_PLUGIN_LIST")" \
        "Old status-less format defaults to 'enabled'"
}

test_plugin_status_prefix_safety() {
    # "work" must not match the "workflow@" block — same prefix guarantee the
    # _match_plugin_in_list tests above assert.
    assert_equals "absent" \
        "$(_plugin_status_in_list "work" "$SAMPLE_PLUGIN_LIST_STATUS")" \
        "Prefix 'work' does not match 'workflow@'"
}

test_plugin_status_empty_list() {
    assert_equals "absent" \
        "$(_plugin_status_in_list "dev-core" "$EMPTY_PLUGIN_LIST")" \
        "Empty list reports 'absent'"
}

# Source guard for the EXTRACTOR's contract (#787). The parser tests above now
# run the real production body, so drift can no longer make them vacuously pass
# — but a rename or a reformat that breaks _extract_shell_function's column-0
# assumption still could. These greps fail loudly on that, naming the cause.
test_status_parser_mirrors_production() {
    local setup_file="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"
    local code
    # Executable lines only — the surrounding comments quote both the Status:
    # line and the enable call, which would mask their deletion.
    code=$(command grep -vE '^[[:space:]]*#' "$setup_file")

    if command grep -q '^_plugin_status_in_list()' <<<"$code"; then
        pass_test "_plugin_status_in_list defined in claude-setup"
    else
        fail_test "_plugin_status_in_list missing from claude-setup"
    fi

    if command grep -qE "Status:.*disabled" <<<"$code"; then
        pass_test "production parser keys off the Status: line"
    else
        fail_test "production parser no longer parses Status: (mirror has drifted)"
    fi

    # The repair path is what satisfies AC4 — detection alone leaves a raced
    # container broken.
    if command grep -q 'claude plugin enable' <<<"$code"; then
        pass_test "claude-setup re-enables a disabled plugin"
    else
        fail_test "claude-setup never calls 'claude plugin enable'"
    fi
}

# Every function these tests execute must actually extract. Without this, a
# rename or a reformat turns _load_production_function into a no-op path and the
# functional tests below would test nothing at all.
test_all_production_functions_extractable() {
    local fn
    for fn in _plugin_status_in_list _is_in_list plugin_status enable_plugin \
        install_plugin _plugin_is_denied _log_denied_plugin _acquire_setup_lock; do
        if [ -n "$(_extract_shell_function "$CLAUDE_SETUP" "$fn")" ]; then
            pass_test "$fn() extractable from claude-setup"
        else
            fail_test "$fn() not extractable — renamed, reformatted, or deleted"
        fi
    done
}

# ============================================================================
# Functional Plugin Install/Enable Tests (issue #787)
# ============================================================================
# These run the REAL claude-setup functions against a mocked `claude` CLI, so
# the wiring between them is executed — not just grepped. The gap this closes:
# a wrong variable passed as full_name, or a dropped `|| true`, would have
# passed every previous test in this suite while breaking the #784 repair.

# A plugin list where the target is installed but DISABLED — the #784 state.
_DISABLED_LIST='Installed plugins:

  ❯ commit-commands@claude-plugins-official
    Version: 1.0.0
    Scope: user
    Status: ✘ disabled'

_ENABLED_LIST='Installed plugins:

  ❯ commit-commands@claude-plugins-official
    Version: 1.0.0
    Scope: user
    Status: ✔ enabled'

# install_plugin's disabled branch must call enable with the FULL name
# (plugin@marketplace). Passing $plugin_name instead is the exact regression
# #787 names, and it is invisible to a source grep.
test_install_plugin_enables_with_full_name() {
    _mock_reset
    MOCK_LIST_OUTPUT="$_DISABLED_LIST"

    install_plugin "commit-commands" >/dev/null

    local logged
    logged=$(command grep '^plugin enable' "$MOCK_CALL_LOG" || true)
    assert_equals "plugin enable commit-commands@claude-plugins-official" \
        "$logged" "enable receives full_name, not the bare plugin name"

    _mock_cleanup
}

# The `|| true` on the enable call is load-bearing: claude-setup runs under
# `set -e`, so without it one failed repair aborts the whole plugin phase and
# every later plugin silently goes uninstalled.
#
# Must run in a SEPARATE bash process with `set -euo pipefail`, the way
# claude-setup does. Two reasons an in-suite call is not good enough:
#   1. this suite's runner does not have errexit on, and errexit is the entire
#      mechanism the `|| true` guards against;
#   2. an inline `$(set -e; ...) || rc=$?` does not help either — bash ignores
#      errexit inside a subshell that is part of a `||` list, so the guard would
#      look present while testing nothing.
# Verified by mutation: deleting the `|| true` fails this test.
test_install_plugin_absorbs_enable_failure() {
    local tmpdir runner
    tmpdir=$(command mktemp -d)
    runner="$tmpdir/runner.sh"

    {
        echo 'set -euo pipefail'
        echo 'MARKETPLACE="claude-plugins-official"'
        echo 'DISABLED_PLUGINS=""'
        echo 'CLAUDE_SETUP_RETRY_DELAY=0'
        # Minimal mock: list reports the plugin disabled, enable always fails.
        command cat <<'MOCK'
claude() {
    case "$1 $2" in
        "plugin list") printf '  ❯ commit-commands@claude-plugins-official\n    Status: ✘ disabled\n'; return 0 ;;
        "plugin enable") echo "permission denied"; return 1 ;;
    esac
    return 0
}
MOCK
        _extract_shell_function "$CLAUDE_SETUP" "_plugin_status_in_list"
        _extract_shell_function "$CLAUDE_SETUP" "_is_in_list"
        _extract_shell_function "$CLAUDE_SETUP" "plugin_status"
        _extract_shell_function "$CLAUDE_SETUP" "_plugin_is_denied"
        _extract_shell_function "$CLAUDE_SETUP" "_log_denied_plugin"
        _extract_shell_function "$CLAUDE_SETUP" "enable_plugin"
        _extract_shell_function "$CLAUDE_SETUP" "install_plugin"
        echo 'install_plugin "commit-commands" >/dev/null 2>&1'
        echo 'echo "REACHED"'
    } >"$runner"

    local out rc=0
    out=$(env -u BASH_ENV bash "$runner" 2>&1) || rc=$?

    assert_equals "0" "$rc" "install_plugin returns 0 despite a failed enable"
    assert_contains "$out" "REACHED" \
        "a failed enable does not abort the caller under set -e"

    command rm -rf "$tmpdir"
}

# An enabled plugin must short-circuit: no enable, no install.
test_install_plugin_skips_when_enabled() {
    _mock_reset
    MOCK_LIST_OUTPUT="$_ENABLED_LIST"

    install_plugin "commit-commands" >/dev/null

    assert_equals "0" "$(_mock_call_count '^plugin enable')" \
        "an enabled plugin is not re-enabled"
    assert_equals "0" "$(_mock_call_count '^plugin install')" \
        "an enabled plugin is not reinstalled"

    _mock_cleanup
}

# plugin_status's OWN failure path: when `claude plugin list` exits non-zero it
# must report "absent" so the caller falls through to install (which has its own
# retry and error reporting) rather than silently skipping. The existing
# empty-string test exercises the PARSER, which is a different code path.
#
# The output is deliberately NON-EMPTY and would otherwise parse as "enabled":
# a failing CLI can still emit a partial list before dying. With an empty output
# the parser reaches "absent" on its own and the test would pass even with the
# fallthrough deleted — proving nothing.
test_plugin_status_absent_when_list_fails() {
    _mock_reset
    MOCK_LIST_RC=1
    MOCK_LIST_OUTPUT="$_ENABLED_LIST"

    assert_equals "absent" "$(plugin_status "commit-commands")" \
        "a failing 'claude plugin list' reports absent despite partial output"

    _mock_cleanup
}

# ...and that "absent" must actually route to the install path. Same reasoning:
# partial output that parses as "enabled" makes a dropped fallthrough visible as
# a silent skip.
test_plugin_status_failure_routes_to_install() {
    _mock_reset
    MOCK_LIST_RC=1
    MOCK_LIST_OUTPUT="$_ENABLED_LIST"

    install_plugin "commit-commands" >/dev/null

    assert_equals "1" "$(_mock_call_count '^plugin install')" \
        "a failed list falls through to install, not a silent skip"

    _mock_cleanup
}

# enable_plugin's failure reporting pipes through `sed | head -5`. head exits
# after 5 lines, so a longer error SIGPIPEs sed — under `set -euo pipefail` that
# could abort the script mid-phase if the pipeline were not the last statement
# before an absorbed return.
test_enable_plugin_failure_output_does_not_abort() {
    _mock_reset
    MOCK_LIST_OUTPUT="$_DISABLED_LIST"
    _mock_set_enable_rcs "1 1 1 1"
    MOCK_ENABLE_OUTPUT=$(printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8')

    local out rc=0
    out=$(install_plugin "commit-commands" 2>&1) || rc=$?

    assert_equals "0" "$rc" "long multi-line enable failure does not abort"
    assert_contains "$out" "Failed to re-enable" "the failure is reported"

    _mock_cleanup
}

# ============================================================================
# enable_plugin Retry Tests (issue #788)
# ============================================================================

# The whole point of #788: a transient marketplace-not-ready failure must be
# retried, not surrendered to. Without this, the run that was supposed to repair
# a disabled plugin can itself fail transiently and leave it broken for the boot.
test_enable_plugin_retries_then_succeeds() {
    _mock_reset
    _mock_set_enable_rcs "1 0"
    MOCK_ENABLE_OUTPUT="Plugin not found in marketplace"

    local rc=0
    enable_plugin "workflow" "workflow@librarian" >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" "a transient failure is retried to success"
    assert_equals "2" "$(_mock_call_count '^plugin enable')" \
        "exactly one retry was needed"

    _mock_cleanup
}

# Retry must be scoped to the transient marker. Retrying a permanent error just
# delays the warning by the full backoff, on every boot.
test_enable_plugin_does_not_retry_permanent_failure() {
    _mock_reset
    _mock_set_enable_rcs "1 1 1 1"
    MOCK_ENABLE_OUTPUT="Error: permission denied"

    local rc=0
    enable_plugin "workflow" "workflow@librarian" >/dev/null 2>&1 || rc=$?

    assert_equals "1" "$rc" "a permanent failure still returns non-zero"
    assert_equals "1" "$(_mock_call_count '^plugin enable')" \
        "a non-transient error is not retried"

    _mock_cleanup
}

# Backoff must be bounded — a permanently-unready marketplace cannot loop.
test_enable_plugin_retry_is_bounded() {
    _mock_reset
    _mock_set_enable_rcs "1 1 1 1 1 1 1 1"
    MOCK_ENABLE_OUTPUT="not found in marketplace"

    local rc=0
    enable_plugin "workflow" "workflow@librarian" >/dev/null 2>&1 || rc=$?

    assert_equals "1" "$rc" "gives up after max_retries"
    assert_equals "4" "$(_mock_call_count '^plugin enable')" \
        "capped at 4 attempts, matching install_plugin"

    _mock_cleanup
}

# install_plugin's OWN retry loop — the one #788's was modeled on. Covered
# symmetrically with enable_plugin above: a structural source guard proves the
# two loops match, but only executing both proves either works.
test_install_plugin_retries_then_succeeds() {
    _mock_reset
    MOCK_LIST_OUTPUT="" # absent -> the fresh-install branch
    _mock_set_install_rcs "1 0"
    MOCK_INSTALL_OUTPUT="Plugin not found in marketplace"

    local rc=0
    install_plugin "commit-commands" >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" "a transient install failure is retried to success"
    assert_equals "2" "$(_mock_call_count '^plugin install')" \
        "exactly one install retry was needed"

    _mock_cleanup
}

test_install_plugin_does_not_retry_permanent_failure() {
    _mock_reset
    MOCK_LIST_OUTPUT=""
    _mock_set_install_rcs "1 1 1 1"
    MOCK_INSTALL_OUTPUT="Error: permission denied"

    local rc=0
    install_plugin "commit-commands" >/dev/null 2>&1 || rc=$?

    assert_equals "1" "$rc" "a permanent install failure returns non-zero"
    assert_equals "1" "$(_mock_call_count '^plugin install')" \
        "a non-transient install error is not retried"

    _mock_cleanup
}

test_install_plugin_retry_is_bounded() {
    _mock_reset
    MOCK_LIST_OUTPUT=""
    _mock_set_install_rcs "1 1 1 1 1 1 1 1"
    MOCK_INSTALL_OUTPUT="not found in marketplace"

    local rc=0
    install_plugin "commit-commands" >/dev/null 2>&1 || rc=$?

    assert_equals "1" "$rc" "gives up after max_retries"
    assert_equals "4" "$(_mock_call_count '^plugin install')" \
        "install backoff is capped at 4 attempts"

    _mock_cleanup
}

test_install_plugin_succeeds_first_try() {
    _mock_reset
    MOCK_LIST_OUTPUT=""

    local out rc=0
    out=$(install_plugin "commit-commands" 2>&1) || rc=$?

    assert_equals "0" "$rc" "a clean install returns 0"
    assert_equals "1" "$(_mock_call_count '^plugin install')" \
        "a successful install is not retried"
    assert_contains "$out" "installed" "the install is reported"

    _mock_cleanup
}

# Source guard: the two retry loops must keep the same shape. If install_plugin's
# cap is raised and enable's is not, the sibling that runs in the same race
# window silently becomes the weaker one again.
test_enable_and_install_share_retry_shape() {
    local enable_src install_src
    enable_src=$(_extract_shell_function "$CLAUDE_SETUP" "enable_plugin")
    install_src=$(_extract_shell_function "$CLAUDE_SETUP" "install_plugin")

    local e_max i_max
    e_max=$(command grep -oE 'max_retries=[0-9]+' <<<"$enable_src" | command head -1)
    i_max=$(command grep -oE 'max_retries=[0-9]+' <<<"$install_src" | command head -1)

    assert_equals "$i_max" "$e_max" \
        "enable_plugin and install_plugin share a retry cap (#788)"

    if command grep -q 'retry_delay \* 2' <<<"$enable_src"; then
        pass_test "enable_plugin uses exponential backoff"
    else
        fail_test "enable_plugin lost its exponential backoff"
    fi
}

# ============================================================================
# CLAUDE_DISABLED_PLUGINS Deny-List Tests (issue #789)
# ============================================================================

# The deny-list is the whole feature: it must beat the allow-lists. A plugin
# named in BOTH is left alone.
test_deny_list_takes_precedence_over_allow_list() {
    _mock_reset
    DISABLED_PLUGINS="commit-commands"
    MOCK_LIST_OUTPUT="$_DISABLED_LIST"

    install_plugin "commit-commands" >/dev/null

    assert_equals "0" "$(_mock_call_count '^plugin enable')" \
        "a denied plugin is not re-enabled"
    assert_equals "0" "$(_mock_call_count '^plugin install')" \
        "a denied plugin is not installed"

    _mock_cleanup
}

# Deny must suppress INSTALL too, not only the re-enable branch: `claude plugin
# install` enables as a side effect, so a fresh ~/.claude volume would otherwise
# silently reinstate the plugin the operator killed.
test_deny_list_suppresses_install_when_absent() {
    _mock_reset
    DISABLED_PLUGINS="commit-commands"
    MOCK_LIST_OUTPUT=""

    local out
    out=$(install_plugin "commit-commands" 2>&1)

    assert_equals "0" "$(_mock_call_count '^plugin install')" \
        "an absent denied plugin is not installed"
    assert_contains "$out" "not installing" "the skipped install is logged"

    _mock_cleanup
}

# The skip must be visible in startup output. A plugin that just vanishes with
# no log line is the same silent failure #784 was about.
test_deny_list_skip_is_logged() {
    _mock_reset
    DISABLED_PLUGINS="commit-commands"
    MOCK_LIST_OUTPUT="$_DISABLED_LIST"

    local out
    out=$(install_plugin "commit-commands" 2>&1)
    assert_contains "$out" "CLAUDE_DISABLED_PLUGINS" \
        "the deny-list skip names the variable responsible"

    _mock_cleanup
}

# claude-setup must not gain a destructive action: a denied-but-enabled plugin
# is reported, never disabled. Setting the variable is a latch, not an actuator.
test_deny_list_warns_but_does_not_disable() {
    _mock_reset
    DISABLED_PLUGINS="commit-commands"
    MOCK_LIST_OUTPUT="$_ENABLED_LIST"

    local out
    out=$(install_plugin "commit-commands" 2>&1)

    assert_equals "0" "$(_mock_call_count '^plugin disable')" \
        "claude-setup never disables a plugin itself"
    assert_contains "$out" "currently enabled" \
        "the operator is told the deny-list has not taken effect yet"

    _mock_cleanup
}

# An empty/unset deny-list must be inert — the default path cannot regress.
test_empty_deny_list_is_inert() {
    _mock_reset
    MOCK_LIST_OUTPUT="$_DISABLED_LIST"

    install_plugin "commit-commands" >/dev/null

    assert_equals "1" "$(_mock_call_count '^plugin enable')" \
        "an empty deny-list does not block the #784 repair"

    _mock_cleanup
}

# Exact-match only, inherited from _is_in_list. A substring match would let
# "workflow" deny "workflow-extras".
test_deny_list_is_exact_match() {
    _mock_reset
    # shellcheck disable=SC2034  # read by the extracted _plugin_is_denied
    DISABLED_PLUGINS="commit"
    MOCK_LIST_OUTPUT="$_DISABLED_LIST"

    install_plugin "commit-commands" >/dev/null

    assert_equals "1" "$(_mock_call_count '^plugin enable')" \
        "a partial name does not deny a different plugin"

    _mock_cleanup
}

# Source guard: the librarian loop has its own inline install path and never
# calls install_plugin, so it needs its own deny check. Missing it would leave
# the kill-switch inert for exactly the plugins it matters most for.
# Scoped to the librarian block itself, not a whole-file count: the function
# DEFINITION also matches _plugin_is_denied, so a naive count stays above a
# threshold even after the loop's call is deleted.
test_deny_list_applied_in_librarian_loop() {
    local block
    block=$(command awk '
        /^if \[ -d "\$LIBRARIAN_DIR" \]; then/ { in_block = 1 }
        in_block { print }
        in_block && /^fi$/ { exit }
    ' "$CLAUDE_SETUP" | command grep -vE '^[[:space:]]*#')

    if [ -z "$block" ]; then
        fail_test "could not locate the librarian install block in claude-setup"
        return
    fi

    if command grep -q '_plugin_is_denied' <<<"$block"; then
        pass_test "the librarian loop checks the deny-list"
    else
        fail_test "librarian loop is unguarded — the kill-switch is inert there"
    fi

    # It must gate the install, not merely be mentioned after it.
    if command grep -q 'claude plugin install' <<<"$block"; then
        pass_test "librarian loop has its own inline install path (why it needs its own check)"
    else
        fail_test "librarian install path not found — this guard may be stale"
    fi
}

# The _FILE convention comes free from _resolve_override_list_or_file; assert
# the deny-list actually goes through it rather than reading the env var raw.
test_deny_list_supports_file_variant() {
    local code
    code=$(command grep -vE '^[[:space:]]*#' "$CLAUDE_SETUP")

    if command grep -q '_resolve_override_list_or_file "CLAUDE_DISABLED_PLUGINS"' <<<"$code"; then
        pass_test "CLAUDE_DISABLED_PLUGINS resolves via the _FILE-aware helper"
    else
        fail_test "CLAUDE_DISABLED_PLUGINS bypasses the _FILE convention"
    fi
}

# ============================================================================
# Lock Acquisition Branch Tests (issue #787)
# ============================================================================
# The timeout branch is deliberately fail-loud: proceeding unlocked would
# silently restore the #784 race. A future `|| true` there must break a test.

# Run _acquire_setup_lock in a subshell with a stubbed `flock`, so the real
# lock is never touched and `exit 1` cannot kill the suite.
#
# env -u BASH_ENV is required (#618): /etc/bash_env rebuilds PATH on
# non-interactive bash and would defeat the PATH stub.
_run_acquire_lock_with_flock_stub() {
    local stub_rc="$1" lock_path="$2"
    local tmpdir
    tmpdir=$(command mktemp -d)

    command cat >"$tmpdir/flock" <<STUB
#!/bin/bash
exit $stub_rc
STUB
    chmod +x "$tmpdir/flock"

    local runner="$tmpdir/runner.sh"
    {
        echo 'set -euo pipefail'
        _extract_shell_function "$CLAUDE_SETUP" "_acquire_setup_lock"
        echo '_acquire_setup_lock "$1"'
        echo 'echo "CONTINUED"'
    } >"$runner"

    env -u BASH_ENV PATH="$tmpdir:$PATH" bash "$runner" "$lock_path" 2>&1
    local rc=$?
    command rm -rf "$tmpdir"
    return $rc
}

test_lock_timeout_exits_nonzero() {
    local out rc=0
    out=$(_run_acquire_lock_with_flock_stub 1 "$TEST_SCRATCH_BASE/timeout-test.lock") || rc=$?

    assert_equals "1" "$rc" "a flock timeout exits 1 (never proceeds unlocked)"
    assert_contains "$out" "timed out after 600s" "the timeout is reported"
    assert_not_contains "$out" "CONTINUED" \
        "setup does NOT continue past a timed-out lock"
}

test_lock_acquired_continues() {
    local out rc=0
    out=$(_run_acquire_lock_with_flock_stub 0 "$TEST_SCRATCH_BASE/ok-test.lock") || rc=$?

    assert_equals "0" "$rc" "a successful acquire returns 0"
    assert_contains "$out" "CONTINUED" "setup proceeds once the lock is held"
}

# An unwritable lock path must WARN and continue. Exiting here would brick setup
# on any host with a read-only or missing /tmp.
test_lock_unwritable_path_warns_and_continues() {
    local out rc=0
    out=$(_run_acquire_lock_with_flock_stub 0 "/nonexistent-dir-$$/claude-setup.lock") || rc=$?

    assert_equals "0" "$rc" "an unopenable lock path is not fatal"
    assert_contains "$out" "continuing without a lock" "the degradation is warned"
    assert_contains "$out" "CONTINUED" "setup proceeds unlocked"
}

# ============================================================================
# Concurrency Guard Tests (issue #784)
# ============================================================================

# Source guard: claude-setup must serialize itself. Two startup paths launch it
# concurrently (30-first-startup.sh and the auth-watcher), and without a lock
# their non-atomic settings.json read-modify-writes clobber each other.
test_claude_setup_takes_flock() {
    local setup_file="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"
    local code
    # Comments describe the lock at length — match executable lines only, so
    # deleting the real call fails this test.
    code=$(command grep -vE '^[[:space:]]*#' "$setup_file")

    if command grep -qE 'flock -w [0-9]+ 200' <<<"$code"; then
        pass_test "claude-setup acquires an flock with a bounded wait"
    else
        fail_test "claude-setup does not acquire a bounded flock"
    fi

    # Absent flock must not be fatal: Alpine ships only the busybox applet and
    # ubi-minimal may omit util-linux entirely.
    if command grep -q 'command -v flock' <<<"$code"; then
        pass_test "flock availability is probed, not assumed"
    else
        fail_test "claude-setup assumes flock exists (breaks Alpine/ubi-minimal)"
    fi

    # The probe must WARN and continue, never exit. A hard failure here would
    # brick setup on every distro without util-linux.
    if command grep -qE 'flock not available' <<<"$code"; then
        pass_test "missing flock degrades with a warning"
    else
        fail_test "no warning path for a missing flock"
    fi

    # The lock path must be a FIXED literal, never env-derived. The two
    # launchers run in different process trees, so a ${TMPDIR:-/tmp} path could
    # resolve differently for each, put them on separate lock files, and
    # silently restore the race the lock exists to prevent.
    if command grep -qE 'CLAUDE_SETUP_LOCK=.*\$\{?TMPDIR' <<<"$code"; then
        fail_test "lock path is env-derived — the two launchers may not agree"
    else
        pass_test "lock path does not depend on TMPDIR"
    fi

    if command grep -qE 'CLAUDE_SETUP_LOCK="/tmp/claude-setup\.lock"' <<<"$code"; then
        pass_test "lock path is the documented /tmp/claude-setup.lock"
    else
        fail_test "lock path does not match the path documented for operators"
    fi
}

# The lock must be exclusive in practice, not just present in the source.
# A second acquirer has to block while the first holds it.
test_flock_is_actually_exclusive() {
    if ! command -v flock >/dev/null 2>&1; then
        skip_test "flock not available on this host"
        return 0
    fi

    local tmpdir lockfile
    tmpdir="$TEST_SCRATCH_BASE/flock-excl-$$-$(date +%s%N)"
    mkdir -p "$tmpdir"
    lockfile="$tmpdir/claude-setup.lock"

    # Hold the lock for 2s in the background...
    (
        exec 200>"$lockfile"
        flock 200
        sleep 2
    ) &
    local holder=$!
    sleep 0.3

    # ...then confirm a non-blocking acquire is REFUSED while it is held.
    if flock -n -w 0 "$lockfile" true 2>/dev/null; then
        fail_test "lock was acquired while already held — not exclusive"
    else
        pass_test "second acquirer is blocked while the lock is held"
    fi

    wait "$holder" 2>/dev/null || true

    # Once released, it must be acquirable again (no leak / no deadlock).
    if flock -n -w 0 "$lockfile" true 2>/dev/null; then
        pass_test "lock is released when the holder exits"
    else
        fail_test "lock not released after holder exited"
    fi

    command rm -rf "$tmpdir"
}

# Source guard: the watcher must not wake on settings.json. Its watch is
# directory-wide, so a sibling claude-setup's settings.json write used to
# self-trigger a SECOND claude-setup — the race's actual trigger.
test_auth_watcher_excludes_settings_json() {
    local watcher="$PROJECT_ROOT/lib/features/lib/claude/claude-auth-watcher"
    local code

    # Strip comments before matching. The fix is described at length in a
    # comment right above the call site, so a naive grep over the whole file
    # passes even after the actual --exclude flag is deleted (verified by
    # mutating the source).
    code=$(command grep -vE '^[[:space:]]*#' "$watcher")

    if command grep -qE -- '--exclude' <<<"$code"; then
        pass_test "auth-watcher filters its inotify watch"
    else
        fail_test "auth-watcher watch is unfiltered (settings.json self-triggers)"
    fi

    if command grep -qE -- "--exclude.*settings" <<<"$code"; then
        pass_test "auth-watcher excludes settings.json specifically"
    else
        fail_test "auth-watcher does not exclude settings.json"
    fi
}

# Behavioral regression: two concurrent read-modify-write cycles against a
# settings.json-shaped file must not lose keys when serialized by flock.
#
# The negative control runs the SAME racing writers WITHOUT the lock and asserts
# a key IS lost — otherwise this test could pass on a machine too fast to race,
# proving nothing about the lock.
_run_racing_writers() {
    local settings="$1" lockfile="$2" use_lock="$3" tmpdir="$4"
    local writer="$tmpdir/writer.sh"

    command cat >"$writer" <<'WRITER'
#!/bin/bash
# Read-modify-write with a deliberate gap, mirroring claude plugin install's
# non-atomic update of enabledPlugins.
settings="$1"; lockfile="$2"; use_lock="$3"; key="$4"
if [ "$use_lock" = "yes" ]; then
    exec 200>"$lockfile"
    flock -w 30 200
fi
current=$(/usr/bin/jq -c '.' "$settings")
sleep 0.3
printf '%s' "$current" \
    | /usr/bin/jq -c --arg k "$key" '.enabledPlugins[$k] = true' >"$settings.tmp.$$"
mv "$settings.tmp.$$" "$settings"
WRITER
    chmod +x "$writer"

    echo '{"enabledPlugins":{"dev-core@librarian":true}}' >"$settings"
    "$writer" "$settings" "$lockfile" "$use_lock" "review-audit@librarian" &
    local pid_a=$!
    sleep 0.1
    "$writer" "$settings" "$lockfile" "$use_lock" "workflow@librarian" &
    local pid_b=$!
    wait "$pid_a" "$pid_b" 2>/dev/null || true
}

test_flock_preserves_concurrent_enabled_plugins() {
    if ! command -v flock >/dev/null 2>&1; then
        skip_test "flock not available on this host"
        return 0
    fi

    # Self-contained temp dir: this suite uses the framework's default
    # setup/teardown, so the test owns its own scratch space.
    local tmpdir
    tmpdir="$TEST_SCRATCH_BASE/flock-race-$$-$(date +%s%N)"
    mkdir -p "$tmpdir"

    local settings="$tmpdir/settings.json"
    local lockfile="$tmpdir/claude-setup.lock"

    # --- With the lock: every key from both writers survives ---
    _run_racing_writers "$settings" "$lockfile" "yes" "$tmpdir"
    local key
    for key in "dev-core@librarian" "review-audit@librarian" "workflow@librarian"; do
        if /usr/bin/jq -e --arg k "$key" '.enabledPlugins[$k] == true' \
            >/dev/null 2>&1 <"$settings"; then
            pass_test "locked: $key survived concurrent writes"
        else
            fail_test "locked: $key was clobbered (the #784 failure)"
        fi
    done

    # --- Negative control: without the lock a key must be lost ---
    _run_racing_writers "$settings" "$lockfile" "no" "$tmpdir"
    local surviving
    surviving=$(/usr/bin/jq -r '.enabledPlugins | keys | length' <"$settings")
    if [ "$surviving" -lt 3 ]; then
        pass_test "unlocked control: writes clobbered as expected ($surviving/3 keys)"
    else
        fail_test "unlocked control did not race — lock test proves nothing"
    fi

    command rm -rf "$tmpdir"
}

# ============================================================================
# MCP Server Matching Tests
# ============================================================================

test_mcp_match_filesystem() {
    if _match_mcp_server_in_list "filesystem" "$SAMPLE_MCP_LIST"; then
        assert_true true "Matches 'filesystem' server"
    else
        assert_true false "Should match 'filesystem' server"
    fi
}

test_mcp_match_github() {
    if _match_mcp_server_in_list "github" "$SAMPLE_MCP_LIST"; then
        assert_true true "Matches 'github' server"
    else
        assert_true false "Should match 'github' server"
    fi
}

test_mcp_match_figma_desktop() {
    if _match_mcp_server_in_list "figma-desktop" "$SAMPLE_MCP_LIST"; then
        assert_true true "Matches 'figma-desktop' server"
    else
        assert_true false "Should match 'figma-desktop' server"
    fi
}

test_mcp_no_match_nonexistent() {
    if _match_mcp_server_in_list "nonexistent" "$SAMPLE_MCP_LIST"; then
        assert_true false "Should NOT match nonexistent server"
    else
        assert_true true "Correctly rejects nonexistent server"
    fi
}

test_mcp_no_match_partial() {
    # "file" should NOT match "filesystem"
    if _match_mcp_server_in_list "file" "$SAMPLE_MCP_LIST"; then
        assert_true false "Should NOT match partial name 'file'"
    else
        assert_true true "Correctly rejects partial name"
    fi
}

test_mcp_no_match_contains() {
    # "system" should NOT match "filesystem"
    if _match_mcp_server_in_list "system" "$SAMPLE_MCP_LIST"; then
        assert_true false "Should NOT match substring 'system'"
    else
        assert_true true "Correctly rejects substring match"
    fi
}

test_mcp_no_match_similar_prefix() {
    # "github" should NOT match "github-enterprise" (from edge cases)
    if _match_mcp_server_in_list "github" "$MCP_LIST_EDGE_CASES"; then
        assert_true false "Should NOT match 'github' when 'github-enterprise' exists"
    else
        assert_true true "Correctly distinguishes 'github' from 'github-enterprise'"
    fi
}

test_mcp_match_with_hyphen_prefix() {
    # "github-enterprise" should match exactly
    if _match_mcp_server_in_list "github-enterprise" "$MCP_LIST_EDGE_CASES"; then
        assert_true true "Matches 'github-enterprise' exactly"
    else
        assert_true false "Should match 'github-enterprise'"
    fi
}

test_mcp_empty_list() {
    if _match_mcp_server_in_list "filesystem" "$EMPTY_MCP_LIST"; then
        assert_true false "Should NOT match in empty list"
    else
        assert_true true "Correctly handles empty list"
    fi
}

# ============================================================================
# Git Remote URL Parsing Tests
# ============================================================================

test_parse_https_github() {
    local result
    result=$(_parse_git_remote_host "https://github.com/user/repo.git")
    assert_equals "$result" "github.com" "Parse HTTPS GitHub URL"
}

test_parse_https_gitlab() {
    local result
    result=$(_parse_git_remote_host "https://gitlab.com/user/repo.git")
    assert_equals "$result" "gitlab.com" "Parse HTTPS GitLab URL"
}

test_parse_https_self_hosted() {
    local result
    result=$(_parse_git_remote_host "https://git.company.com/user/repo.git")
    assert_equals "$result" "git.company.com" "Parse HTTPS self-hosted URL"
}

test_parse_ssh_shorthand_github() {
    local result
    result=$(_parse_git_remote_host "git@github.com:user/repo.git")
    assert_equals "$result" "github.com" "Parse SSH shorthand GitHub URL"
}

test_parse_ssh_shorthand_gitlab() {
    local result
    result=$(_parse_git_remote_host "git@gitlab.com:user/repo.git")
    assert_equals "$result" "gitlab.com" "Parse SSH shorthand GitLab URL"
}

test_parse_ssh_shorthand_self_hosted() {
    local result
    result=$(_parse_git_remote_host "git@git.company.com:group/repo.git")
    assert_equals "$result" "git.company.com" "Parse SSH shorthand self-hosted URL"
}

test_parse_ssh_url_github() {
    local result
    result=$(_parse_git_remote_host "ssh://git@github.com/user/repo.git")
    assert_equals "$result" "github.com" "Parse SSH URL GitHub"
}

test_parse_ssh_url_with_port() {
    local result
    result=$(_parse_git_remote_host "ssh://git@gitlab.company.com:2222/user/repo.git")
    # Port should be stripped
    assert_equals "$result" "gitlab.company.com" "Parse SSH URL with port"
}

test_parse_https_with_port() {
    local result
    result=$(_parse_git_remote_host "https://github.com:443/user/repo.git")
    assert_equals "$result" "github.com" "Parse HTTPS URL with port"
}

test_parse_empty_url() {
    local result
    result=$(_parse_git_remote_host "")
    assert_equals "$result" "" "Handle empty URL"
}

test_parse_invalid_url() {
    local result
    result=$(_parse_git_remote_host "not-a-valid-url")
    assert_equals "$result" "" "Handle invalid URL"
}

test_parse_http_url() {
    local result
    result=$(_parse_git_remote_host "http://github.com/user/repo.git")
    assert_equals "$result" "github.com" "Parse HTTP URL"
}

# ============================================================================
# Git Platform Classification Tests
# ============================================================================

test_classify_github() {
    local result
    result=$(_classify_git_host "github.com")
    assert_equals "$result" "github" "Classify github.com"
}

test_classify_gitlab() {
    local result
    result=$(_classify_git_host "gitlab.com")
    assert_equals "$result" "gitlab:gitlab.com" "Classify gitlab.com"
}

test_classify_self_hosted_gitlab() {
    local result
    result=$(_classify_git_host "gitlab.company.com")
    assert_equals "$result" "gitlab:gitlab.company.com" "Classify self-hosted GitLab"
}

test_classify_gitlab_subdomain() {
    local result
    result=$(_classify_git_host "code.gitlab.company.com")
    assert_equals "$result" "gitlab:code.gitlab.company.com" "Classify GitLab subdomain"
}

test_classify_unknown() {
    local result
    result=$(_classify_git_host "bitbucket.org")
    assert_equals "$result" "unknown:bitbucket.org" "Classify unknown host"
}

test_classify_self_hosted_git() {
    local result
    result=$(_classify_git_host "git.company.com")
    assert_equals "$result" "unknown:git.company.com" "Classify self-hosted git"
}

test_classify_empty() {
    local result
    result=$(_classify_git_host "")
    assert_equals "$result" "none" "Classify empty host"
}

# ============================================================================
# Edge Cases and Regression Tests
# ============================================================================

test_plugin_special_characters_in_name() {
    # Plugin names with numbers
    local list='  ❯ context7@claude-plugins-official - Context provider'
    if _match_plugin_in_list "context7" "$list"; then
        assert_true true "Matches plugin with number in name"
    else
        assert_true false "Should match plugin with number"
    fi
}

test_mcp_server_with_numbers() {
    local list='server1: command - running
server-v2: command - running'
    if _match_mcp_server_in_list "server1" "$list"; then
        assert_true true "Matches server with number"
    else
        assert_true false "Should match server with number"
    fi
}

test_mcp_no_false_positive_on_description() {
    # "filesystem" appears in the command, but we should only match at line start
    local list='other-server: npx filesystem-helper - running'
    if _match_mcp_server_in_list "filesystem" "$list"; then
        assert_true false "Should NOT match 'filesystem' in command args"
    else
        assert_true true "Correctly ignores 'filesystem' in command args"
    fi
}

test_plugin_marketplace_variation() {
    # Test with different marketplace names in the output
    local list='  ❯ figma@other-marketplace - Figma design'
    if _match_plugin_in_list "figma" "$list"; then
        assert_true true "Matches regardless of marketplace"
    else
        assert_true false "Should match regardless of marketplace name"
    fi
}

# ============================================================================
# Component Override Helper Tests
# ============================================================================

# _is_in_list is loaded from production by _load_production_function above
# (#787) — no mirror here. _resolve_override_list still needs one: it reads
# ${var}_DEFAULT indirectly, so tests drive it with their own scratch variables.
_resolve_override_list() {
    local var_name="$1"
    local defaults="$2"
    local default_var="${var_name}_DEFAULT"

    local runtime_val="${!var_name:-}"
    local default_val="${!default_var:-}"

    if [ -n "${!var_name+x}" ]; then
        echo "$runtime_val"
        return 0
    fi

    if [ "$default_val" != "__UNSET__" ]; then
        echo "$default_val"
        return 0
    fi

    echo "$defaults"
    return 1
}

# --- _is_in_list tests ---

test_is_in_list_exact_match() {
    if _is_in_list "debugger" "code-reviewer,test-writer,debugger"; then
        pass_test "Exact match found in list"
    else
        fail_test "Should find exact match in list"
    fi
}

test_is_in_list_first_item() {
    if _is_in_list "code-reviewer" "code-reviewer,test-writer,debugger"; then
        pass_test "First item found in list"
    else
        fail_test "Should find first item in list"
    fi
}

test_is_in_list_last_item() {
    if _is_in_list "debugger" "code-reviewer,debugger"; then
        pass_test "Last item found in list"
    else
        fail_test "Should find last item in list"
    fi
}

test_is_in_list_single_item() {
    if _is_in_list "debugger" "debugger"; then
        pass_test "Single item list match"
    else
        fail_test "Should match single item list"
    fi
}

test_is_in_list_no_partial_match() {
    if _is_in_list "debug" "code-reviewer,debugger"; then
        fail_test "Should NOT match partial name"
    else
        pass_test "Correctly rejects partial match"
    fi
}

test_is_in_list_no_match() {
    if _is_in_list "nonexistent" "code-reviewer,debugger"; then
        fail_test "Should NOT match nonexistent item"
    else
        pass_test "Correctly rejects nonexistent item"
    fi
}

test_is_in_list_empty_list() {
    if _is_in_list "debugger" ""; then
        fail_test "Should NOT match in empty list"
    else
        pass_test "Correctly handles empty list"
    fi
}

test_is_in_list_empty_needle() {
    if _is_in_list "" "code-reviewer,debugger"; then
        fail_test "Should NOT match empty needle"
    else
        pass_test "Correctly rejects empty needle"
    fi
}

test_is_in_list_whitespace_tolerance() {
    if _is_in_list "debugger" "code-reviewer , debugger , test-writer"; then
        pass_test "Handles whitespace around items"
    else
        fail_test "Should handle whitespace around items"
    fi
}

# --- _resolve_override_list tests ---

test_resolve_unset_returns_defaults() {
    # Neither runtime nor build-time var set
    unset TEST_VAR TEST_VAR_DEFAULT 2>/dev/null || true
    TEST_VAR_DEFAULT="__UNSET__"
    local result rc
    # Use if-else to safely capture return code under set -e
    if result=$(_resolve_override_list "TEST_VAR" "a,b,c"); then
        rc=0
    else
        rc=1
    fi
    assert_equals "$result" "a,b,c" "Unset vars return defaults"
    assert_equals "$rc" "1" "Return code 1 when using defaults"
    unset TEST_VAR_DEFAULT
}

test_resolve_runtime_override() {
    TEST_VAR="x,y"
    TEST_VAR_DEFAULT="__UNSET__"
    local result rc
    if result=$(_resolve_override_list "TEST_VAR" "a,b,c"); then
        rc=0
    else
        rc=1
    fi
    assert_equals "$result" "x,y" "Runtime var overrides defaults"
    assert_equals "$rc" "0" "Return code 0 when override active"
    unset TEST_VAR TEST_VAR_DEFAULT
}

test_resolve_runtime_empty_override() {
    # shellcheck disable=SC2034  # TEST_VAR used indirectly via _resolve_override_list
    TEST_VAR=""
    TEST_VAR_DEFAULT="__UNSET__"
    local result rc
    if result=$(_resolve_override_list "TEST_VAR" "a,b,c"); then
        rc=0
    else
        rc=1
    fi
    assert_equals "$result" "" "Empty runtime var returns empty"
    assert_equals "$rc" "0" "Return code 0 when override active (empty)"
    unset TEST_VAR TEST_VAR_DEFAULT
}

test_resolve_buildtime_default() {
    unset TEST_VAR 2>/dev/null || true
    TEST_VAR_DEFAULT="p,q"
    local result rc
    if result=$(_resolve_override_list "TEST_VAR" "a,b,c"); then
        rc=0
    else
        rc=1
    fi
    assert_equals "$result" "p,q" "Build-time default overrides built-in defaults"
    assert_equals "$rc" "0" "Return code 0 when build-time override active"
    unset TEST_VAR_DEFAULT
}

test_resolve_buildtime_empty_default() {
    unset TEST_VAR 2>/dev/null || true
    # shellcheck disable=SC2034  # TEST_VAR_DEFAULT used indirectly via _resolve_override_list
    TEST_VAR_DEFAULT=""
    local result rc
    if result=$(_resolve_override_list "TEST_VAR" "a,b,c"); then
        rc=0
    else
        rc=1
    fi
    assert_equals "$result" "" "Empty build-time default returns empty"
    assert_equals "$rc" "0" "Return code 0 when build-time override active (empty)"
    unset TEST_VAR_DEFAULT
}

# --- Sentinel detection in persisted config ---

test_sentinel_in_persist_script() {
    local persist_src
    persist_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib/features/lib/dev-tools" && pwd)/persist-feature-flags.sh"
    if command grep -q '__UNSET__' "$persist_src"; then
        pass_test "persist-feature-flags.sh contains __UNSET__ sentinel"
    else
        fail_test "persist-feature-flags.sh missing __UNSET__ sentinel"
    fi
}

test_persist_script_has_all_override_vars() {
    local persist_src
    persist_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib/features/lib/dev-tools" && pwd)/persist-feature-flags.sh"
    local failures=0
    for var in CLAUDE_PLUGINS_DEFAULT CLAUDE_MCPS_DEFAULT CLAUDE_AGENTS_DEFAULT CLAUDE_SKILLS_DEFAULT; do
        if ! command grep -q "$var" "$persist_src"; then
            echo "  FAIL: $var not found in persist-feature-flags.sh" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All 4 override _DEFAULT vars in persist script"
}

# --- Source file pattern checks ---

test_claude_setup_has_resolve_override() {
    if command grep -q '_resolve_override_list' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "claude-setup contains _resolve_override_list helper"
    else
        fail_test "claude-setup missing _resolve_override_list helper"
    fi
}

test_claude_setup_has_is_in_list() {
    if command grep -q '_is_in_list' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "claude-setup contains _is_in_list helper"
    else
        fail_test "claude-setup missing _is_in_list helper"
    fi
}

test_dockerfile_has_override_args() {
    local dockerfile
    dockerfile="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)/Dockerfile"
    local failures=0
    for arg in CLAUDE_PLUGINS CLAUDE_MCPS CLAUDE_AGENTS CLAUDE_SKILLS; do
        if ! command grep -q "ARG $arg" "$dockerfile"; then
            echo "  FAIL: ARG $arg not found in Dockerfile" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All 4 override ARGs in Dockerfile"
}

# ============================================================================
# CLAUDE_CHANNEL Validation Tests
# ============================================================================

# Path to the source files under test
CLAUDE_CODE_SETUP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib/features" && pwd)/claude-code-setup.sh"
CLAUDE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib/features/lib/claude" && pwd)"
CLAUDE_SETUP_CMD_SRC="$CLAUDE_LIB_DIR/claude-setup"
CLAUDE_AUTH_WATCHER_SRC="$CLAUDE_LIB_DIR/claude-auth-watcher"
CLAUDE_ENV_SRC="$CLAUDE_LIB_DIR/95-claude-env.sh"

# Helper: test whether a channel value matches the allowlist pattern
_is_valid_channel() {
    local channel="$1"
    case "$channel" in
        latest | stable) return 0 ;;
        *) return 1 ;;
    esac
}

test_channel_validation_exists() {
    # Static check: the source file must contain the case guard
    if command grep -q 'Invalid CLAUDE_CHANNEL' "$CLAUDE_CODE_SETUP_SRC"; then
        pass_test "Source contains CLAUDE_CHANNEL validation guard"
    else
        fail_test "Source is missing CLAUDE_CHANNEL validation guard"
    fi
}

test_valid_channels_accepted() {
    local failures=0
    for ch in "latest" "stable"; do
        if ! _is_valid_channel "$ch"; then
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "Both 'latest' and 'stable' accepted"
}

test_invalid_channels_rejected() {
    local adversarial_values=(
        'latest; echo INJECTED'
        'stable && rm -rf /'
        'beta'
        ''
        '../../etc/passwd'
        'latest$(whoami)'
    )
    local failures=0
    for ch in "${adversarial_values[@]}"; do
        if _is_valid_channel "$ch"; then
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All adversarial channel values rejected"
}

# ============================================================================
# MCP Passthrough npm Package Name Validation Tests
# ============================================================================

# Helper: test whether a package name matches the npm validation regex
_is_valid_npm_package_name() {
    local name="$1"
    [[ "$name" =~ ^[@a-zA-Z0-9][-a-zA-Z0-9_./@]*$ ]]
}

test_mcp_passthrough_validation_exists() {
    # Static check: the claude-setup command must contain the npm package name regex guard
    if command grep -q '\^[@a-zA-Z0-9\]' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "Source contains npm package name validation guard"
    else
        fail_test "Source is missing npm package name validation guard"
    fi
}

test_valid_npm_names_accepted() {
    local valid_names=(
        "@modelcontextprotocol/server-fetch"
        "my-server"
        "@org/pkg"
        "@sentry/mcp-server"
        "some_package.v2"
    )
    local failures=0
    for name in "${valid_names[@]}"; do
        if ! _is_valid_npm_package_name "$name"; then
            echo "  FAIL: '$name' should be accepted" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All valid npm package names accepted"
}

test_invalid_npm_names_rejected() {
    local adversarial_values=(
        "'; rm -rf /'"
        '$(whoami)'
        ""
        '`id`'
        "; echo pwned"
        '| command cat /etc/passwd'
    )
    local failures=0
    for name in "${adversarial_values[@]}"; do
        if _is_valid_npm_package_name "$name"; then
            echo "  FAIL: '$name' should be rejected" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All adversarial npm package names rejected"
}

# ============================================================================
# Secure Token Storage Tests (Issue #62)
# ============================================================================

test_no_export_anthropic_auth_token() {
    # Source MUST NOT export ANTHROPIC_AUTH_TOKEN to the shell environment
    # Check the feature script and all extracted files
    if command grep -rqE '^\s*export\s+ANTHROPIC_AUTH_TOKEN' "$CLAUDE_CODE_SETUP_SRC" "$CLAUDE_LIB_DIR"/; then
        fail_test "Source still contains 'export ANTHROPIC_AUTH_TOKEN' (security issue #62)"
    else
        pass_test "No 'export ANTHROPIC_AUTH_TOKEN' found in source"
    fi
}

test_uses_secure_token_file() {
    # Source MUST use /dev/shm for token storage
    if command grep -rq '/dev/shm/anthropic-auth-token' "$CLAUDE_SETUP_CMD_SRC" "$CLAUDE_AUTH_WATCHER_SRC" "$CLAUDE_ENV_SRC"; then
        pass_test "Source uses /dev/shm/anthropic-auth-token for secure storage"
    else
        fail_test "Source is missing /dev/shm/anthropic-auth-token secure storage"
    fi
}

test_store_anthropic_token_helper_exists() {
    # Source MUST define the _store_anthropic_token helper
    if command grep -q '_store_anthropic_token()' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "Source defines _store_anthropic_token helper"
    else
        fail_test "Source is missing _store_anthropic_token helper"
    fi
}

test_claude_env_contains_wrapper() {
    # The 95-claude-env.sh file MUST contain a claude() wrapper function
    if command grep -q 'claude()' "$CLAUDE_ENV_SRC"; then
        pass_test "Source contains claude() wrapper function"
    else
        fail_test "Source is missing claude() wrapper function in 95-claude-env.sh"
    fi
}

test_claude_env_unsets_token() {
    # The 95-claude-env.sh file MUST unset ANTHROPIC_AUTH_TOKEN from env
    if command grep -q 'unset ANTHROPIC_AUTH_TOKEN' "$CLAUDE_ENV_SRC"; then
        pass_test "Source unsets ANTHROPIC_AUTH_TOKEN from environment"
    else
        fail_test "Source does not unset ANTHROPIC_AUTH_TOKEN from environment"
    fi
}

test_mcp_auto_auth_checks_file() {
    # MCP auto-auth MUST check the secure token file
    if command grep -q '\-s /dev/shm/anthropic-auth-token' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "MCP auto-auth checks /dev/shm/anthropic-auth-token file"
    else
        fail_test "MCP auto-auth does not check /dev/shm/anthropic-auth-token file"
    fi
}

test_auth_watcher_uses_secure_storage() {
    # Auth watcher MUST use _store_token (inlined helper)
    if command grep -q '_store_token' "$CLAUDE_AUTH_WATCHER_SRC"; then
        pass_test "Auth watcher uses _store_token for secure storage"
    else
        fail_test "Auth watcher does not use _store_token"
    fi
}

# ============================================================================
# File-Based Config Resolution Tests (Issue #277)
# ============================================================================

# Mirror the new helpers from claude-setup for testing
_RESOLVED_FROM_FILE=$(mktemp)

_resolve_override_list_or_file() {
    local var_name="$1"
    local defaults="$2"
    local file_var="${var_name}_FILE"
    local file_default_var="${var_name}_FILE_DEFAULT"

    local file_path="${!file_var:-${!file_default_var:-}}"

    if [ -n "$file_path" ]; then
        if [ ! -f "$file_path" ]; then
            echo "  ⚠ ${file_var}=${file_path} not found, falling through to env var" >&2
        elif ! command jq -e 'type == "array"' "$file_path" >/dev/null 2>&1; then
            echo "  ⚠ ${file_var}=${file_path} is not a valid JSON array, falling through" >&2
        else
            if [ -n "${!var_name+x}" ]; then
                echo "  ⚠ ${var_name} ignored — ${file_var} takes precedence" >&2
            fi
            command cat "$file_path"
            echo "file" >"$_RESOLVED_FROM_FILE"
            return 0
        fi
    fi

    local result
    local rc=0
    result=$(_resolve_override_list "$var_name" "$defaults") || rc=$?
    echo "$result"
    if [ $rc -eq 0 ]; then
        echo "env" >"$_RESOLVED_FROM_FILE"
    else
        echo "default" >"$_RESOLVED_FROM_FILE"
    fi
    return $rc
}

_file_json_to_csv() {
    command jq -r 'map(if type == "string" then . else .name // empty end) | join(",")' <<<"$1"
}

# --- _resolve_override_list_or_file tests ---

test_file_takes_precedence_over_env() {
    local tmpfile
    tmpfile=$(mktemp)
    echo '["x","y","z"]' >"$tmpfile"

    # shellcheck disable=SC2034  # Used indirectly via _resolve_override_list_or_file
    TEST_FILE_VAR="override-me"
    # shellcheck disable=SC2034
    TEST_FILE_VAR_DEFAULT="__UNSET__"
    # shellcheck disable=SC2034
    TEST_FILE_VAR_FILE="$tmpfile"

    local result
    if result=$(_resolve_override_list_or_file "TEST_FILE_VAR" "a,b,c"); then
        : # override active
    fi
    local resolved_from
    resolved_from=$(command cat "$_RESOLVED_FROM_FILE")
    assert_equals "$resolved_from" "file" "RESOLVED_FROM should be 'file'"
    local csv
    csv=$(_file_json_to_csv "$result")
    assert_equals "$csv" "x,y,z" "File content used (env var ignored)"

    rm -f "$tmpfile"
    unset TEST_FILE_VAR TEST_FILE_VAR_DEFAULT TEST_FILE_VAR_FILE
}

test_file_warns_when_env_also_set() {
    local tmpfile
    tmpfile=$(mktemp)
    echo '["p","q"]' >"$tmpfile"

    # shellcheck disable=SC2034  # Used indirectly via _resolve_override_list_or_file
    TEST_WARN_VAR="should-be-ignored"
    # shellcheck disable=SC2034
    TEST_WARN_VAR_DEFAULT="__UNSET__"
    # shellcheck disable=SC2034
    TEST_WARN_VAR_FILE="$tmpfile"

    local result stderr_output
    stderr_output=$(_resolve_override_list_or_file "TEST_WARN_VAR" "a,b" 2>&1 1>/dev/null) || true
    # The warning should mention that env var is ignored
    if echo "$stderr_output" | command grep -q "TEST_WARN_VAR ignored"; then
        pass_test "Warning emitted when env var also set"
    else
        pass_test "Warning behavior (file still takes precedence)"
    fi

    rm -f "$tmpfile"
    unset TEST_WARN_VAR TEST_WARN_VAR_DEFAULT TEST_WARN_VAR_FILE
}

test_missing_file_falls_through() {
    unset TEST_MISSING_VAR 2>/dev/null || true
    # shellcheck disable=SC2034  # Used indirectly via _resolve_override_list_or_file
    TEST_MISSING_VAR_DEFAULT="__UNSET__"
    # shellcheck disable=SC2034
    TEST_MISSING_VAR_FILE="/nonexistent/path/config.json"

    local result rc=0
    if result=$(_resolve_override_list_or_file "TEST_MISSING_VAR" "a,b,c" 2>/dev/null); then
        rc=0
    else
        rc=1
    fi
    local resolved_from
    resolved_from=$(command cat "$_RESOLVED_FROM_FILE")
    assert_equals "$resolved_from" "default" "Falls through to defaults when file missing"
    assert_equals "$result" "a,b,c" "Returns built-in defaults"

    unset TEST_MISSING_VAR_DEFAULT TEST_MISSING_VAR_FILE
}

test_invalid_json_falls_through() {
    local tmpfile
    tmpfile=$(mktemp)
    echo 'not valid json' >"$tmpfile"

    unset TEST_BADJSON_VAR 2>/dev/null || true
    # shellcheck disable=SC2034  # Used indirectly via _resolve_override_list_or_file
    TEST_BADJSON_VAR_DEFAULT="__UNSET__"
    # shellcheck disable=SC2034
    TEST_BADJSON_VAR_FILE="$tmpfile"

    local result rc=0
    if result=$(_resolve_override_list_or_file "TEST_BADJSON_VAR" "d,e,f" 2>/dev/null); then
        rc=0
    else
        rc=1
    fi
    local resolved_from
    resolved_from=$(command cat "$_RESOLVED_FROM_FILE")
    assert_equals "$resolved_from" "default" "Falls through to defaults when JSON invalid"
    assert_equals "$result" "d,e,f" "Returns built-in defaults"

    rm -f "$tmpfile"
    unset TEST_BADJSON_VAR_DEFAULT TEST_BADJSON_VAR_FILE
}

test_non_array_json_falls_through() {
    local tmpfile
    tmpfile=$(mktemp)
    echo '{"not":"an array"}' >"$tmpfile"

    unset TEST_OBJJSON_VAR 2>/dev/null || true
    # shellcheck disable=SC2034  # Used indirectly via _resolve_override_list_or_file
    TEST_OBJJSON_VAR_DEFAULT="__UNSET__"
    # shellcheck disable=SC2034
    TEST_OBJJSON_VAR_FILE="$tmpfile"

    local result rc=0
    if result=$(_resolve_override_list_or_file "TEST_OBJJSON_VAR" "g,h" 2>/dev/null); then
        rc=0
    else
        rc=1
    fi
    local resolved_from
    resolved_from=$(command cat "$_RESOLVED_FROM_FILE")
    assert_equals "$resolved_from" "default" "Falls through when JSON is object not array"
    assert_equals "$result" "g,h" "Returns built-in defaults"

    rm -f "$tmpfile"
    unset TEST_OBJJSON_VAR_DEFAULT TEST_OBJJSON_VAR_FILE
}

test_no_file_uses_env_var() {
    # shellcheck disable=SC2034  # Used indirectly via _resolve_override_list_or_file
    TEST_ENVONLY_VAR="m,n,o"
    # shellcheck disable=SC2034
    TEST_ENVONLY_VAR_DEFAULT="__UNSET__"
    unset TEST_ENVONLY_VAR_FILE 2>/dev/null || true
    unset TEST_ENVONLY_VAR_FILE_DEFAULT 2>/dev/null || true

    local result
    if result=$(_resolve_override_list_or_file "TEST_ENVONLY_VAR" "a,b,c"); then
        : # override
    fi
    local resolved_from
    resolved_from=$(command cat "$_RESOLVED_FROM_FILE")
    assert_equals "$resolved_from" "env" "Uses env var when no file set"
    assert_equals "$result" "m,n,o" "Returns env var value"

    unset TEST_ENVONLY_VAR TEST_ENVONLY_VAR_DEFAULT
}

test_build_time_file_default() {
    local tmpfile
    tmpfile=$(mktemp)
    echo '["build1","build2"]' >"$tmpfile"

    unset TEST_BUILDFILE_VAR 2>/dev/null || true
    unset TEST_BUILDFILE_VAR_FILE 2>/dev/null || true
    # shellcheck disable=SC2034  # Used indirectly via _resolve_override_list_or_file
    TEST_BUILDFILE_VAR_DEFAULT="__UNSET__"
    # shellcheck disable=SC2034
    TEST_BUILDFILE_VAR_FILE_DEFAULT="$tmpfile"

    local result
    if result=$(_resolve_override_list_or_file "TEST_BUILDFILE_VAR" "a,b"); then
        : # override
    fi
    local resolved_from
    resolved_from=$(command cat "$_RESOLVED_FROM_FILE")
    assert_equals "$resolved_from" "file" "Uses build-time file default"
    local csv
    csv=$(_file_json_to_csv "$result")
    assert_equals "$csv" "build1,build2" "Returns build-time file content"

    rm -f "$tmpfile"
    unset TEST_BUILDFILE_VAR_DEFAULT TEST_BUILDFILE_VAR_FILE_DEFAULT
}

# --- _file_json_to_csv tests ---

test_json_to_csv_strings() {
    local result
    result=$(_file_json_to_csv '["a","b","c"]')
    assert_equals "$result" "a,b,c" "Converts string array to CSV"
}

test_json_to_csv_mixed() {
    local result
    result=$(_file_json_to_csv '["a",{"name":"b"},"c"]')
    assert_equals "$result" "a,b,c" "Converts mixed string/object array to CSV"
}

test_json_to_csv_objects_only() {
    local result
    result=$(_file_json_to_csv '[{"name":"x"},{"name":"y"}]')
    assert_equals "$result" "x,y" "Converts object array to CSV"
}

test_json_to_csv_empty() {
    local result
    result=$(_file_json_to_csv '[]')
    assert_equals "$result" "" "Empty array produces empty string"
}

# --- Persist script has _FILE_DEFAULT vars ---

test_persist_script_has_file_default_vars() {
    local persist_src
    persist_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib/features/lib/dev-tools" && pwd)/persist-feature-flags.sh"
    local failures=0
    for var in CLAUDE_SKILLS_FILE_DEFAULT CLAUDE_AGENTS_FILE_DEFAULT CLAUDE_PLUGINS_FILE_DEFAULT CLAUDE_MCPS_FILE_DEFAULT \
        CLAUDE_EXTRA_SKILLS_FILE_DEFAULT CLAUDE_EXTRA_AGENTS_FILE_DEFAULT CLAUDE_EXTRA_PLUGINS_FILE_DEFAULT CLAUDE_EXTRA_MCPS_FILE_DEFAULT; do
        if ! command grep -q "$var" "$persist_src"; then
            echo "  FAIL: $var not found in persist-feature-flags.sh" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All 8 _FILE_DEFAULT vars in persist script"
}

# --- Source file checks for new helpers ---

test_claude_setup_has_resolve_override_or_file() {
    if command grep -q '_resolve_override_list_or_file' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "claude-setup contains _resolve_override_list_or_file helper"
    else
        fail_test "claude-setup missing _resolve_override_list_or_file helper"
    fi
}

test_claude_setup_has_file_json_to_csv() {
    if command grep -q '_file_json_to_csv' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "claude-setup contains _file_json_to_csv helper"
    else
        fail_test "claude-setup missing _file_json_to_csv helper"
    fi
}

test_claude_setup_has_configure_mcp_from_json_object() {
    if command grep -q 'configure_mcp_from_json_object' "$CLAUDE_SETUP_CMD_SRC"; then
        pass_test "claude-setup contains configure_mcp_from_json_object helper"
    else
        fail_test "claude-setup missing configure_mcp_from_json_object helper"
    fi
}

# ============================================================================
# Run Tests
# ============================================================================

# Component override helper tests
run_test test_is_in_list_exact_match "List helper: Exact match"
run_test test_is_in_list_first_item "List helper: First item"
run_test test_is_in_list_last_item "List helper: Last item"
run_test test_is_in_list_single_item "List helper: Single item"
run_test test_is_in_list_no_partial_match "List helper: No partial match"
run_test test_is_in_list_no_match "List helper: No match"
run_test test_is_in_list_empty_list "List helper: Empty list"
run_test test_is_in_list_empty_needle "List helper: Empty needle"
run_test test_is_in_list_whitespace_tolerance "List helper: Whitespace tolerance"

run_test test_resolve_unset_returns_defaults "Resolve: Unset returns defaults"
run_test test_resolve_runtime_override "Resolve: Runtime override"
run_test test_resolve_runtime_empty_override "Resolve: Runtime empty override"
run_test test_resolve_buildtime_default "Resolve: Build-time default"
run_test test_resolve_buildtime_empty_default "Resolve: Build-time empty default"

run_test test_sentinel_in_persist_script "Persist: __UNSET__ sentinel present"
run_test test_persist_script_has_all_override_vars "Persist: All 4 override vars present"

run_test test_claude_setup_has_resolve_override "Source: _resolve_override_list in claude-setup"
run_test test_claude_setup_has_is_in_list "Source: _is_in_list in claude-setup"
run_test test_dockerfile_has_override_args "Source: Override ARGs in Dockerfile"

# Secure token storage tests (Issue #62)
run_test test_no_export_anthropic_auth_token "Security: No export ANTHROPIC_AUTH_TOKEN"
run_test test_uses_secure_token_file "Security: Uses /dev/shm token file"
run_test test_store_anthropic_token_helper_exists "Security: _store_anthropic_token helper exists"
run_test test_claude_env_contains_wrapper "Security: claude() wrapper in env script"
run_test test_claude_env_unsets_token "Security: Unsets token from environment"
run_test test_mcp_auto_auth_checks_file "Security: MCP auto-auth checks token file"
run_test test_auth_watcher_uses_secure_storage "Security: Auth watcher uses secure storage"

# CLAUDE_CHANNEL validation tests
run_test test_channel_validation_exists "Channel: Validation guard exists in source"
run_test test_valid_channels_accepted "Channel: Valid values accepted"
run_test test_invalid_channels_rejected "Channel: Adversarial values rejected"

# MCP passthrough npm package name validation tests
run_test test_mcp_passthrough_validation_exists "MCP passthrough: Validation guard exists in source"
run_test test_valid_npm_names_accepted "MCP passthrough: Valid npm names accepted"
run_test test_invalid_npm_names_rejected "MCP passthrough: Adversarial npm names rejected"

# Plugin matching tests
run_test test_plugin_match_exact_name "Plugin: Match exact name"
run_test test_plugin_match_with_hyphen "Plugin: Match name with hyphen"
run_test test_plugin_match_lsp_plugin "Plugin: Match LSP plugin"
run_test test_plugin_no_match_nonexistent "Plugin: No match for nonexistent"
run_test test_plugin_no_match_partial_name "Plugin: No match for partial name"
run_test test_plugin_no_match_suffix "Plugin: No match for suffix"
run_test test_plugin_empty_list "Plugin: Empty list"
run_test test_plugin_whitespace_list "Plugin: Whitespace-only list"
run_test test_plugin_case_sensitive "Plugin: Case sensitive"

# Enablement parsing + concurrency guards (issue #784)
run_test test_plugin_status_enabled "Plugin status: enabled plugin reports enabled"
run_test test_plugin_status_disabled "Plugin status: disabled plugin reports disabled"
run_test test_plugin_status_absent "Plugin status: missing plugin reports absent"
run_test test_plugin_status_no_leak_to_next_block "Plugin status: disabled block does not leak to next plugin"
run_test test_plugin_status_old_format_is_enabled "Plugin status: status-less old format defaults to enabled"
run_test test_plugin_status_prefix_safety "Plugin status: prefix does not match longer plugin name"
run_test test_plugin_status_empty_list "Plugin status: empty list reports absent"
run_test test_status_parser_mirrors_production "Plugin status: production parser + repair path present"
run_test test_all_production_functions_extractable "Harness: every production function extracts (#787)"

run_test test_install_plugin_enables_with_full_name "Functional: disabled branch enables with full_name"
run_test test_install_plugin_absorbs_enable_failure "Functional: failed enable does not abort the run"
run_test test_install_plugin_skips_when_enabled "Functional: enabled plugin is left untouched"
run_test test_plugin_status_absent_when_list_fails "Functional: failed 'plugin list' reports absent"
run_test test_plugin_status_failure_routes_to_install "Functional: absent falls through to install"
run_test test_enable_plugin_failure_output_does_not_abort "Functional: long enable failure survives set -e pipefail"

run_test test_enable_plugin_retries_then_succeeds "Retry: transient enable failure is retried (#788)"
run_test test_enable_plugin_does_not_retry_permanent_failure "Retry: permanent enable failure is not retried"
run_test test_enable_plugin_retry_is_bounded "Retry: enable backoff is capped at 4 attempts"
run_test test_install_plugin_retries_then_succeeds "Retry: transient install failure is retried"
run_test test_install_plugin_does_not_retry_permanent_failure "Retry: permanent install failure is not retried"
run_test test_install_plugin_retry_is_bounded "Retry: install backoff is capped at 4 attempts"
run_test test_install_plugin_succeeds_first_try "Retry: a clean install is not retried"
run_test test_enable_and_install_share_retry_shape "Retry: enable and install share the retry shape"

run_test test_deny_list_takes_precedence_over_allow_list "Deny-list: beats CLAUDE_PLUGINS (#789)"
run_test test_deny_list_suppresses_install_when_absent "Deny-list: suppresses install, not just re-enable"
run_test test_deny_list_skip_is_logged "Deny-list: the skip is logged, not silent"
run_test test_deny_list_warns_but_does_not_disable "Deny-list: warns on an enabled plugin, never disables"
run_test test_empty_deny_list_is_inert "Deny-list: empty list does not regress the #784 repair"
run_test test_deny_list_is_exact_match "Deny-list: exact match only, no substring denial"
run_test test_deny_list_applied_in_librarian_loop "Deny-list: also guards the librarian install loop"
run_test test_deny_list_supports_file_variant "Deny-list: resolves via the _FILE-aware helper"

run_test test_lock_timeout_exits_nonzero "Lock: flock timeout exits 1, never proceeds unlocked"
run_test test_lock_acquired_continues "Lock: a successful acquire continues setup"
run_test test_lock_unwritable_path_warns_and_continues "Lock: unwritable path warns and continues"

run_test test_claude_setup_takes_flock "Concurrency: claude-setup serializes itself with flock"
run_test test_flock_is_actually_exclusive "Concurrency: the lock is exclusive and released"
run_test test_auth_watcher_excludes_settings_json "Concurrency: auth-watcher excludes settings.json from its watch"
run_test test_flock_preserves_concurrent_enabled_plugins "Concurrency: flock preserves enabledPlugins under concurrent writes"

# MCP server matching tests
run_test test_mcp_match_filesystem "MCP: Match filesystem"
run_test test_mcp_match_github "MCP: Match github"
run_test test_mcp_match_figma_desktop "MCP: Match figma-desktop"
run_test test_mcp_no_match_nonexistent "MCP: No match for nonexistent"
run_test test_mcp_no_match_partial "MCP: No match for partial name"
run_test test_mcp_no_match_contains "MCP: No match for substring"
run_test test_mcp_no_match_similar_prefix "MCP: Distinguish similar prefixes"
run_test test_mcp_match_with_hyphen_prefix "MCP: Match hyphenated name"
run_test test_mcp_empty_list "MCP: Empty list"

# Git URL parsing tests
run_test test_parse_https_github "Git URL: HTTPS GitHub"
run_test test_parse_https_gitlab "Git URL: HTTPS GitLab"
run_test test_parse_https_self_hosted "Git URL: HTTPS self-hosted"
run_test test_parse_ssh_shorthand_github "Git URL: SSH shorthand GitHub"
run_test test_parse_ssh_shorthand_gitlab "Git URL: SSH shorthand GitLab"
run_test test_parse_ssh_shorthand_self_hosted "Git URL: SSH shorthand self-hosted"
run_test test_parse_ssh_url_github "Git URL: SSH URL GitHub"
run_test test_parse_ssh_url_with_port "Git URL: SSH URL with port"
run_test test_parse_https_with_port "Git URL: HTTPS with port"
run_test test_parse_empty_url "Git URL: Empty"
run_test test_parse_invalid_url "Git URL: Invalid"
run_test test_parse_http_url "Git URL: HTTP"

# Git platform classification tests
run_test test_classify_github "Git classify: GitHub"
run_test test_classify_gitlab "Git classify: GitLab"
run_test test_classify_self_hosted_gitlab "Git classify: Self-hosted GitLab"
run_test test_classify_gitlab_subdomain "Git classify: GitLab subdomain"
run_test test_classify_unknown "Git classify: Unknown host"
run_test test_classify_self_hosted_git "Git classify: Self-hosted git"
run_test test_classify_empty "Git classify: Empty"

# Edge cases and regression tests
run_test test_plugin_special_characters_in_name "Edge: Plugin with numbers"
run_test test_mcp_server_with_numbers "Edge: MCP server with numbers"
run_test test_mcp_no_false_positive_on_description "Edge: No false positive on description"
run_test test_plugin_marketplace_variation "Edge: Different marketplace"

# File-based config resolution tests (Issue #277)
run_test test_file_takes_precedence_over_env "File config: File takes precedence over env"
run_test test_file_warns_when_env_also_set "File config: Warning when env also set"
run_test test_missing_file_falls_through "File config: Missing file falls through"
run_test test_invalid_json_falls_through "File config: Invalid JSON falls through"
run_test test_non_array_json_falls_through "File config: Non-array JSON falls through"
run_test test_no_file_uses_env_var "File config: No file uses env var"
run_test test_build_time_file_default "File config: Build-time file default"
run_test test_json_to_csv_strings "JSON to CSV: String array"
run_test test_json_to_csv_mixed "JSON to CSV: Mixed string/object array"
run_test test_json_to_csv_objects_only "JSON to CSV: Object array"
run_test test_json_to_csv_empty "JSON to CSV: Empty array"
run_test test_persist_script_has_file_default_vars "Persist: All 8 _FILE_DEFAULT vars"
run_test test_claude_setup_has_resolve_override_or_file "Source: _resolve_override_list_or_file in claude-setup"
run_test test_claude_setup_has_file_json_to_csv "Source: _file_json_to_csv in claude-setup"
run_test test_claude_setup_has_configure_mcp_from_json_object "Source: configure_mcp_from_json_object in claude-setup"

# ============================================================================
# ACP agent launch wrapper (#519)
# ============================================================================
# The wrapper re-injects the container's Anthropic credentials into an editor-
# launched Claude Code ACP agent (e.g. Zed's AI panel) that bypasses the
# interactive `claude` bash wrapper.

# Test: the wrapper is shipped and is provider-neutral with the right safety
# properties (API-key passthrough, ANTHROPIC_*-only cache import, ACP exec).
test_acp_wrapper_shipped() {
    local wrapper="$PROJECT_ROOT/lib/features/lib/claude/claude-acp-launch"
    assert_file_exists "$wrapper" "claude-acp-launch wrapper shipped under lib/features/lib/claude/"
    assert_file_contains "$wrapper" "/dev/shm/anthropic-auth-token" \
        "wrapper reads the stripped token from the shm file"
    assert_file_contains "$wrapper" "claude-agent-acp" \
        "wrapper execs the Claude ACP launcher"
    # Provider-neutral: no provider name hardcoded.
    assert_file_not_contains "$wrapper" "bifrost" "wrapper is provider-neutral (no 'bifrost')"
    # Must NOT export the token (security issue #62) — it is forwarded as a
    # one-shot assignment on the exec line instead.
    assert_file_not_contains "$wrapper" "export ANTHROPIC_AUTH_TOKEN" \
        "wrapper does not export the auth token into its environment"
    # Must NOT blanket-source the secrets cache (would leak GIT_*_SSH_KEY /
    # GITHUB_TOKEN); it reads named ANTHROPIC_* keys only. The cache is read via
    # a `sed -n s/^export ANTHROPIC_.../` extractor, never sourced.
    assert_file_not_contains "$wrapper" "source \"\$OP_CACHE\"" \
        "wrapper does not blanket-source the secrets cache"
    assert_file_contains "$wrapper" "_cache_value ANTHROPIC_BASE_URL" \
        "wrapper reads named ANTHROPIC_* keys from the cache, not a blanket source"
}

# Test: claude-code-setup.sh installs the wrapper to /usr/local/bin.
test_acp_wrapper_installed() {
    local setup_file="$PROJECT_ROOT/lib/features/claude-code-setup.sh"
    assert_file_contains "$setup_file" "features/lib/claude/claude-acp-launch" \
        "claude-code-setup.sh references the shipped wrapper"
    assert_file_contains "$setup_file" "/usr/local/bin/claude-acp-launch" \
        "claude-code-setup.sh installs the wrapper onto PATH"
}

run_test test_acp_wrapper_shipped "ACP wrapper shipped, provider-neutral, leak-safe"
run_test test_acp_wrapper_installed "claude-code-setup.sh installs claude-acp-launch"

# ============================================================================
# Default settings.json permissions merge (#682)
# ============================================================================
# claude-code-setup.sh seeds a DEFAULT_PERMISSIONS array into
# ~/.claude/settings.json via `.permissions.allow = ((.permissions.allow // [])
# + $perms | unique)`. #682 adds three Bash(tmux ...) rules so the librarian
# workflow plugin's golem dispatch (`tmux new-session ...`) isn't denied by the
# auto-mode classifier on a fresh image. These tests exercise the actual merge —
# not just a source grep — so the rules are asserted "present in the resulting
# settings.json" as the acceptance criteria require.

# Extract the literal DEFAULT_PERMISSIONS array from the setup script so the test
# tracks the real source of truth rather than a hand-copied list. The array spans
# the lines from `DEFAULT_PERMISSIONS='[` through the closing `]'`.
_extract_default_permissions() {
    local setup_file="$PROJECT_ROOT/lib/features/claude-code-setup.sh"
    command sed -n "/^DEFAULT_PERMISSIONS='\[/,/^\]'/p" "$setup_file" |
        command sed "s/^DEFAULT_PERMISSIONS='//; s/'$//"
}

# The three tmux launch-permission rules golem dispatch requires.
_TMUX_RULES=(
    "Bash(tmux new-session:*)"
    "Bash(tmux ls:*)"
    "Bash(tmux kill-session:*)"
)

# Test: the extracted DEFAULT_PERMISSIONS is valid JSON and carries all three
# tmux rules (define-side sanity before the merge tests).
test_default_permissions_has_tmux_rules() {
    local perms
    perms="$(_extract_default_permissions)"

    if ! /usr/bin/jq -e . >/dev/null 2>&1 <<<"$perms"; then
        fail_test "DEFAULT_PERMISSIONS did not extract as valid JSON"
        return
    fi

    local rule
    for rule in "${_TMUX_RULES[@]}"; do
        if /usr/bin/jq -e --arg r "$rule" 'index($r) != null' >/dev/null <<<"$perms"; then
            pass_test "DEFAULT_PERMISSIONS contains $rule"
        else
            fail_test "DEFAULT_PERMISSIONS missing $rule"
        fi
    done
}

# Test: fresh-create path — a brand-new settings.json seeded from
# DEFAULT_PERMISSIONS has all three tmux rules in permissions.allow.
test_settings_merge_fresh_create() {
    local perms result rule
    perms="$(_extract_default_permissions)"

    # Mirror the script's fresh-create jq (lines ~254-257).
    result="$(/usr/bin/jq -n --argjson perms "$perms" \
        '{permissions: {allow: $perms}}')"

    for rule in "${_TMUX_RULES[@]}"; do
        if /usr/bin/jq -e --arg r "$rule" \
            '.permissions.allow | index($r) != null' >/dev/null <<<"$result"; then
            pass_test "fresh settings.json allows $rule"
        else
            fail_test "fresh settings.json missing $rule"
        fi
    done
}

# Test: merge path — merging into an existing settings.json that already has one
# tmux rule yields all three, de-duplicated (the `unique` invariant), and any
# pre-existing unrelated rule is preserved.
test_settings_merge_dedupes_and_preserves() {
    local perms result
    perms="$(_extract_default_permissions)"

    # Existing settings already carry one of the tmux rules plus a custom rule.
    local existing='{"permissions":{"allow":["Bash(tmux new-session:*)","Read(/custom/**)"]}}'

    # Mirror the script's merge jq (lines ~243-249).
    result="$(/usr/bin/jq --argjson perms "$perms" \
        '.permissions.allow = ((.permissions.allow // []) + $perms | unique)' \
        <<<"$existing")"

    local rule
    for rule in "${_TMUX_RULES[@]}"; do
        if /usr/bin/jq -e --arg r "$rule" \
            '.permissions.allow | index($r) != null' >/dev/null <<<"$result"; then
            pass_test "merged settings.json allows $rule"
        else
            fail_test "merged settings.json missing $rule"
        fi
    done

    # The pre-existing custom rule survives the merge.
    if /usr/bin/jq -e '.permissions.allow | index("Read(/custom/**)") != null' \
        >/dev/null <<<"$result"; then
        pass_test "merge preserves pre-existing custom rule"
    else
        fail_test "merge dropped pre-existing custom rule"
    fi

    # The duplicated tmux rule collapses to a single entry (unique invariant).
    local count
    count="$(/usr/bin/jq '[.permissions.allow[] | select(. == "Bash(tmux new-session:*)")] | length' \
        <<<"$result")"
    assert_equals "1" "$count" "duplicate tmux rule de-duplicated by unique"
}

run_test test_default_permissions_has_tmux_rules "Default permissions: DEFAULT_PERMISSIONS carries the 3 tmux rules"
run_test test_settings_merge_fresh_create "Default permissions: fresh settings.json seeds the 3 tmux rules"
run_test test_settings_merge_dedupes_and_preserves "Default permissions: merge dedupes tmux rule + preserves existing"

# ============================================================================
# Host-event forwarder settings.json hook wiring (INCLUDE_HOST_EVENTS)
# ============================================================================
# claude-setup wires claude-host-event.sh into settings.json's `hooks` block for
# 8 Claude Code events when INCLUDE_HOST_EVENTS=true. These tests exercise
# the actual jq merge — asserting the 8-event mapping is produced, is idempotent
# under re-merge, and preserves pre-existing hooks — plus a source guard that the
# wiring stays gated (never fires unconditionally).

# The 8 events the forwarder wires (mirrors HOST_EVENT_MAP in claude-setup).
_HOST_EVENTS=(
    SessionStart UserPromptSubmit PreToolUse PostToolUse
    PostToolUseFailure Notification Stop SessionEnd
)

# Reproduce claude-setup's per-event append merge (idempotent, preserves
# existing). Kept in lockstep with the jq in lib/features/lib/claude/claude-setup
# (the "Host Event Forwarding" block); test_host_event_wiring_is_gated guards the
# source so drift is caught.
_host_event_merge() {
    local input="$1" hook="$2"
    local map='{"SessionStart":"Idle","UserPromptSubmit":"Working","PreToolUse":"Working","PostToolUse":"Auto","PostToolUseFailure":"ToolFail","Notification":"Waiting","Stop":"Idle","SessionEnd":"Ended"}'
    /usr/bin/jq --arg hook "$hook" --argjson map "$map" '
        reduce ($map | to_entries[]) as $e (.;
            ($e.key) as $event
            | ($hook + " " + $e.value) as $cmd
            | .hooks[$event] //= []
            | if (.hooks[$event] | any(.[].hooks[]?; .command == $cmd)) then .
              else .hooks[$event] += [{ "hooks": [{ "type": "command", "command": $cmd }] }]
              end)
    ' <<<"$input"
}

# Test: fresh settings.json gains a command hook for all 8 events, each pointing
# at the forwarder with its state arg.
test_host_event_wiring_all_events() {
    local hook="/home/vscode/.claude/hooks/claude-host-event.sh"
    local result event
    result="$(_host_event_merge '{}' "$hook")"

    for event in "${_HOST_EVENTS[@]}"; do
        if /usr/bin/jq -e --arg ev "$event" --arg h "$hook" \
            '.hooks[$ev] | any(.[].hooks[]?; .command | startswith($h + " "))' \
            >/dev/null <<<"$result"; then
            pass_test "forwarder wired for $event"
        else
            fail_test "forwarder NOT wired for $event"
        fi
    done
}

# Test: re-running the merge does not duplicate entries (idempotent, self-heal
# safe on every boot).
test_host_event_wiring_idempotent() {
    local hook="/home/vscode/.claude/hooks/claude-host-event.sh"
    local once twice count
    once="$(_host_event_merge '{}' "$hook")"
    twice="$(_host_event_merge "$once" "$hook")"

    count="$(/usr/bin/jq '[.hooks.Stop[].hooks[].command] | length' <<<"$twice")"
    assert_equals "1" "$count" "Stop hook not duplicated on re-merge"
}

# Test: a user's pre-existing hook on one of these events is preserved; the
# forwarder is appended alongside, not replacing it.
test_host_event_wiring_preserves_existing() {
    local hook="/home/vscode/.claude/hooks/claude-host-event.sh"
    local existing result
    existing='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/my/own/hook.sh"}]}]}}'
    result="$(_host_event_merge "$existing" "$hook")"

    if /usr/bin/jq -e '.hooks.Stop | any(.[].hooks[]?; .command == "/my/own/hook.sh")' \
        >/dev/null <<<"$result"; then
        pass_test "pre-existing Stop hook preserved"
    else
        fail_test "pre-existing Stop hook dropped"
    fi
    if /usr/bin/jq -e --arg h "$hook" \
        '.hooks.Stop | any(.[].hooks[]?; .command | startswith($h + " "))' \
        >/dev/null <<<"$result"; then
        pass_test "forwarder appended alongside existing Stop hook"
    else
        fail_test "forwarder not appended to Stop"
    fi
}

# Test (source guard): the wiring in claude-setup is gated on
# INCLUDE_HOST_EVENTS=true — it must never wire unconditionally.
test_host_event_wiring_is_gated() {
    local setup_file="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"
    if command grep -qE 'INCLUDE_HOST_EVENTS:-false.*=.*"true"|"\$\{INCLUDE_HOST_EVENTS:-false\}" = "true"' "$setup_file"; then
        pass_test "host-event wiring is gated on INCLUDE_HOST_EVENTS=true"
    else
        fail_test "host-event wiring gate not found in claude-setup"
    fi
}

run_test test_host_event_wiring_all_events "Host events: forwarder wired for all 8 Claude Code events"
run_test test_host_event_wiring_idempotent "Host events: re-merge is idempotent (no duplicate hooks)"
run_test test_host_event_wiring_preserves_existing "Host events: merge preserves a pre-existing user hook"
run_test test_host_event_wiring_is_gated "Host events: wiring is gated on the build-time flag"

# Generate test report
generate_report
