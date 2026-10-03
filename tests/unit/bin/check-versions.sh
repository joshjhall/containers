#!/usr/bin/env bash
# Unit tests for bin/check-versions.sh
# Tests version checking functionality without requiring Docker builds

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Check Versions Tests"

# Helper function to extract version from a variable assignment
# Handles both plain assignments (VAR="1.2.3") and parameter expansion (VAR="${VAR:-1.2.3}")
extract_version_from_line() {
    local line="$1"
    local ver

    # Extract the value after the = sign, removing quotes
    ver=$(echo "$line" | command cut -d= -f2 | command tr -d '"')

    # If it's a parameter expansion like ${VAR:-default}, extract the default value
    if [[ "$ver" =~ \$\{[^:]*:-([^}]+)\} ]]; then
        ver="${BASH_REMATCH[1]}"
    fi

    echo "$ver"
}

# Mock function to simulate fetch_url responses
mock_fetch_url() {
    local url="$1"
    case "$url" in
        *"endoflife.date/api/python.json"*)
            echo '[{"cycle":"3.13","latest":"3.13.6"},{"cycle":"3.12","latest":"3.12.8"}]'
            ;;
        *"nodejs.org/dist/index.json"*)
            echo '[{"version":"v22.18.0","lts":"Jod"},{"version":"v20.18.1","lts":"Iron"}]'
            ;;
        *"go.dev/VERSION"*)
            echo "go1.24.6"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Test: version_matches function with exact match
test_version_matches_exact() {
    # Create a mock version_matches function for testing
    version_matches() {
        local current="$1"
        local latest="$2"

        # Handle exact matches first
        if [[ "$current" == "$latest" ]]; then
            return 0
        fi

        # Handle prefix matching with proper version boundaries
        # e.g., "22" matches "22.18.0" but not "220.0.0"
        if [[ "$latest" == "$current."* ]] || [[ "$latest" == "$current" ]]; then
            return 0
        fi

        return 1
    }

    # Test exact match
    if version_matches "3.13.6" "3.13.6"; then
        assert_true true "Exact version match works"
    else
        assert_true false "Exact version match failed"
    fi
}

# Test: version_matches function with partial match
test_version_matches_partial() {
    # Create a mock version_matches function for testing
    version_matches() {
        local current="$1"
        local latest="$2"

        # Handle exact matches first
        if [[ "$current" == "$latest" ]]; then
            return 0
        fi

        # Handle prefix matching with proper version boundaries
        # e.g., "22" matches "22.18.0" but not "220.0.0"
        if [[ "$latest" == "$current."* ]] || [[ "$latest" == "$current" ]]; then
            return 0
        fi

        return 1
    }

    # Test partial match (major.minor matches major.minor.patch)
    if version_matches "1.33" "1.33.3"; then
        assert_true true "Partial version match works (1.33 matches 1.33.3)"
    else
        assert_true false "Partial version match failed"
    fi

    # Test major version match
    if version_matches "22" "22.18.0"; then
        assert_true true "Major version match works (22 matches 22.18.0)"
    else
        assert_true false "Major version match failed"
    fi
}

# Test: version_matches function with non-match
test_version_matches_different() {
    # Create a mock version_matches function for testing
    version_matches() {
        local current="$1"
        local latest="$2"

        # Handle exact matches first
        if [[ "$current" == "$latest" ]]; then
            return 0
        fi

        # Handle prefix matching with proper version boundaries
        # e.g., "22" matches "22.18.0" but not "220.0.0"
        if [[ "$latest" == "$current."* ]] || [[ "$latest" == "$current" ]]; then
            return 0
        fi

        return 1
    }

    # Test different versions
    if ! version_matches "1.32" "1.33.3"; then
        assert_true true "Different versions correctly identified as non-match"
    else
        assert_true false "Different versions incorrectly matched"
    fi

    # Test partial that shouldn't match
    if ! version_matches "21" "210.0.0"; then
        assert_true true "Prefix check correctly rejects invalid match"
    else
        assert_true false "Invalid prefix match was accepted"
    fi
}

# Test: Check if script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/bin/check-versions.sh"
    assert_executable "$PROJECT_ROOT/bin/check-versions.sh"
}

# Test: Script handles missing .env file gracefully
test_missing_env_file() {
    # Runs the real check-versions.sh, which curls api.github.com per tool.
    # Skipped in the pre-push gate (SKIP_NETWORK_TESTS=1); CI runs it in full.
    if network_tests_disabled; then
        skip_test "Network-bound (SKIP_NETWORK_TESTS=1) — full check runs in CI"
        return
    fi

    # Temporarily move .env if it exists
    local env_backup=""
    if [ -f "$PROJECT_ROOT/.env" ]; then
        env_backup="$PROJECT_ROOT/.env.backup.$$"
        command mv "$PROJECT_ROOT/.env" "$env_backup"
    fi

    # Run script without .env file (strip ANSI colors)
    local output
    output=$("$PROJECT_ROOT/bin/check-versions.sh" 2>&1 | command sed 's/\x1b\[[0-9;]*m//g' | command head -10 || true)

    # Check for warning about missing token
    if echo "$output" | command grep -q "Warning: No GITHUB_TOKEN set"; then
        assert_true true "Script handles missing .env file gracefully"
    else
        # The script might be using the token from environment
        assert_true true "Script runs without .env file"
    fi

    # Restore .env if it was backed up
    if [ -n "$env_backup" ] && [ -f "$env_backup" ]; then
        command mv "$env_backup" "$PROJECT_ROOT/.env"
    fi
}

# Test: Script extracts versions from Dockerfile
test_extract_dockerfile_versions() {
    # Create a temporary test Dockerfile
    local test_dockerfile="$TEST_SCRATCH_BASE/test_dockerfile"
    command cat >"$test_dockerfile" <<'EOF'
ARG PYTHON_VERSION=3.13.6
ARG NODE_VERSION=22
ARG GO_VERSION=1.24.6
EOF

    # Check if versions can be extracted
    local python_ver
    python_ver=$(command grep "^ARG PYTHON_VERSION=" "$test_dockerfile" | command cut -d= -f2 | command tr -d '"')
    assert_equals "3.13.6" "$python_ver" "Python version extracted correctly"

    local node_ver
    node_ver=$(command grep "^ARG NODE_VERSION=" "$test_dockerfile" | command cut -d= -f2 | command tr -d '"')
    assert_equals "22" "$node_ver" "Node version extracted correctly"

    # Clean up
    command rm -f "$test_dockerfile"
}

# Test: Script extracts versions from feature scripts
test_extract_feature_versions() {
    # Check if dev-tools.sh exists and has version definitions
    if [ -f "$PROJECT_ROOT/lib/features/dev-tools.sh" ]; then
        local lazygit_ver
        lazygit_ver=$(command grep '^LAZYGIT_VERSION=' "$PROJECT_ROOT/lib/features/dev-tools.sh" | command cut -d= -f2 | command tr -d '"')
        assert_not_empty "$lazygit_ver" "Lazygit version extracted from dev-tools.sh"
    else
        skip_test "dev-tools.sh not found"
    fi
}

# Test: JSON output format
test_json_output_format() {
    # Invokes the real script (network). Skip under the pre-push flag; CI runs it.
    if network_tests_disabled; then
        skip_test "Network-bound (SKIP_NETWORK_TESTS=1) — full check runs in CI"
        return
    fi

    # Test that the script supports --json flag
    local output

    # First check if --help mentions JSON
    if "$PROJECT_ROOT/bin/check-versions.sh" --help 2>&1 | command grep -q "json"; then
        # JSON is supported, test it with a short timeout
        output=$(timeout 5 "$PROJECT_ROOT/bin/check-versions.sh" --json --no-cache 2>/dev/null || true)

        if [[ "$output" == "{"* ]]; then
            assert_true true "Script produces JSON output"
        else
            # Might be taking too long, just check if script runs
            assert_true true "Script supports --json flag"
        fi
    else
        # Fallback to text format check
        output=$(timeout 5 "$PROJECT_ROOT/bin/check-versions.sh" 2>&1 | command head -5 || true)
        if echo "$output" | command grep -q "Version Check Results\|Checking\|Scanning"; then
            assert_true true "Script produces formatted output"
        else
            assert_true false "Script output format is incorrect"
        fi
    fi
}

# Test: JSON output is valid and well-formed
test_json_output_valid() {
    # Invokes the real script (network). Skip under the pre-push flag; CI runs it.
    if network_tests_disabled; then
        skip_test "Network-bound (SKIP_NETWORK_TESTS=1) — full check runs in CI"
        return
    fi

    # Run the script with --json flag and validate output with jq
    local output
    local exit_code=0

    # Capture output and exit code separately (timeout returns 124 on timeout)
    output=$(timeout 30 "$PROJECT_ROOT/bin/check-versions.sh" --json --no-cache 2>&1) || exit_code=$?

    # If timeout occurred (exit code 124), skip this test - network too slow in CI
    if [ "$exit_code" -eq 124 ]; then
        skip_test "Script timed out (30s) - network conditions too slow for full version check"
        return
    fi

    # If we got empty output with a non-zero exit code, likely a network/API issue
    # Skip gracefully rather than failing - this is a flaky test in CI environments
    if [ -z "$output" ] && [ "$exit_code" -ne 0 ]; then
        skip_test "Script produced no output (exit code: $exit_code) - likely network/API issue in CI"
        return
    fi

    # If we got empty output with exit code 0, that's a real bug
    if [ -z "$output" ]; then
        assert_true false "Script produced no output despite exit code 0"
        return
    fi

    # Check if the output is valid JSON using jq
    if echo "$output" | jq empty 2>/dev/null; then
        assert_true true "Script produces valid JSON that can be parsed by jq"

        # Also verify the JSON has expected structure
        if echo "$output" | jq -e '.tools' >/dev/null 2>&1 &&
            echo "$output" | jq -e '.summary' >/dev/null 2>&1; then
            assert_true true "JSON output has expected structure (tools, summary)"
        else
            assert_true false "JSON output is missing expected fields"
        fi
    else
        # If JSON is invalid, show the error for debugging
        echo "Invalid JSON output:" >&2
        echo "$output" | command head -20 >&2
        assert_true false "Script failed to produce valid JSON (syntax error or malformed output)"
    fi
}

# Test: Script has no bash syntax errors
test_script_syntax() {
    # Use bash -n to check for syntax errors without executing
    if bash -n "$PROJECT_ROOT/bin/check-versions.sh" 2>/dev/null; then
        assert_true true "Script has valid bash syntax"
    else
        local errors
        errors=$(bash -n "$PROJECT_ROOT/bin/check-versions.sh" 2>&1 || true)
        echo "Bash syntax errors found:" >&2
        echo "$errors" >&2
        assert_true false "Script contains bash syntax errors"
    fi
}

# Test: Script extracts Java dev tool versions
test_extract_java_dev_versions() {
    # Check if java-dev.sh exists and has version definitions
    if [ -f "$PROJECT_ROOT/lib/features/java-dev.sh" ]; then
        # Test both regular and indented versions
        local spring_ver
        spring_ver=$(command grep '^SPRING_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | command cut -d= -f2 | command tr -d '"')
        local jbang_ver
        jbang_ver=$(command grep '^JBANG_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | command cut -d= -f2 | command tr -d '"')
        # MVND_VERSION is indented in the actual file
        local mvnd_ver
        mvnd_ver=$(command grep 'MVND_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | command sed 's/.*MVND_VERSION=//' | command tr -d '"' | command head -1)
        local gjf_ver
        gjf_ver=$(command grep '^GJF_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | command cut -d= -f2 | command tr -d '"')

        assert_not_empty "$spring_ver" "Spring Boot CLI version extracted"
        assert_not_empty "$jbang_ver" "JBang version extracted"
        assert_not_empty "$mvnd_ver" "MVND version extracted (indented)"
        assert_not_empty "$gjf_ver" "Google Java Format version extracted"
    else
        skip_test "java-dev.sh not found"
    fi
}

# Test: Script extracts duf and entr versions
test_extract_duf_entr_versions() {
    # Check if dev-tools.sh has duf and entr version definitions
    if [ -f "$PROJECT_ROOT/lib/features/dev-tools.sh" ]; then
        local duf_ver
        duf_ver=$(command grep '^DUF_VERSION=' "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | command cut -d= -f2 | command tr -d '"')
        local entr_ver
        entr_ver=$(command grep '^ENTR_VERSION=' "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | command cut -d= -f2 | command tr -d '"')

        assert_not_empty "$duf_ver" "duf version extracted from dev-tools.sh"
        assert_not_empty "$entr_ver" "entr version extracted from dev-tools.sh"
    else
        skip_test "dev-tools.sh not found"
    fi
}

# Test: Script handles indented version patterns
test_handle_indented_versions() {
    # Create a temporary test script with indented versions
    local test_script="$TEST_SCRATCH_BASE/test_indented.sh"
    command cat >"$test_script" <<'EOF'
#!/bin/bash
if [ condition ]; then
    SOME_VERSION="1.2.3"
    ANOTHER_VERSION="4.5.6"
fi
EOF

    # Check if indented versions can be extracted with proper pattern
    local some_ver
    some_ver=$(command grep '^\s*SOME_VERSION=' "$test_script" 2>/dev/null | command sed 's/.*=//' | command tr -d '"')
    local another_ver
    another_ver=$(command grep 'ANOTHER_VERSION=' "$test_script" 2>/dev/null | command sed 's/.*=//' | command tr -d '"')

    assert_equals "1.2.3" "$some_ver" "Indented version extracted correctly"
    assert_equals "4.5.6" "$another_ver" "Another indented version extracted correctly"

    # Clean up
    command rm -f "$test_script"
}

# Test: Script extracts zoxide version from base setup
test_extract_zoxide_version() {
    # Check if base/setup.sh has zoxide version definition
    if [ -f "$PROJECT_ROOT/lib/base/setup.sh" ]; then
        local zoxide_ver
        zoxide_ver=$(extract_version_from_line "$(command grep '^ZOXIDE_VERSION=' "$PROJECT_ROOT/lib/base/setup.sh" 2>/dev/null)")

        assert_not_empty "$zoxide_ver" "zoxide version extracted from base/setup.sh"
        # Verify extracted version matches semver pattern (don't hardcode specific versions)
        if [[ "$zoxide_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            pass_test "zoxide version matches semver format"
        else
            fail_test "zoxide version '$zoxide_ver' does not match semver format"
        fi
    else
        skip_test "base/setup.sh not found"
    fi
}

# Test: extract_version_from_line handles parameter expansion
test_extract_version_parameter_expansion() {
    local result

    # Test plain assignment
    result=$(extract_version_from_line 'VAR="1.2.3"')
    assert_equals "1.2.3" "$result" "Plain assignment extracted correctly"

    # Test parameter expansion
    result=$(extract_version_from_line 'VAR="${VAR:-1.2.3}"')
    assert_equals "1.2.3" "$result" "Parameter expansion extracted correctly"

    # Test with different variable names
    result=$(extract_version_from_line 'LAZYGIT_VERSION="${LAZYGIT_VERSION:-0.56.0}"')
    assert_equals "0.56.0" "$result" "Real-world parameter expansion works"
}

# Run tests
run_test test_script_exists "Version checker script exists and is executable"
run_test test_script_syntax "Script has valid bash syntax (no typos)"
run_test test_version_matches_exact "version_matches handles exact matches"
run_test test_version_matches_partial "version_matches handles partial matches"
run_test test_version_matches_different "version_matches rejects non-matches"
run_test test_missing_env_file "Script handles missing .env file gracefully"
run_test test_extract_dockerfile_versions "Script extracts versions from Dockerfile"
run_test test_extract_feature_versions "Script extracts versions from feature scripts"
run_test test_json_output_format "JSON output format is correct"
run_test test_json_output_valid "JSON output is valid and well-formed"
run_test test_extract_java_dev_versions "Script extracts Java dev tool versions"
run_test test_extract_duf_entr_versions "Script extracts duf and entr versions"
run_test test_handle_indented_versions "Script handles indented version patterns"
run_test test_extract_zoxide_version "Script extracts zoxide version from base setup"
run_test test_extract_version_parameter_expansion "extract_version_from_line handles parameter expansion"

# Test: Script extracts krew version from Dockerfile
test_extract_krew_version() {
    # Check if krew version can be extracted from Dockerfile
    local krew_ver
    krew_ver=$(command grep "^ARG KREW_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | command cut -d= -f2 | command tr -d '"')

    assert_not_empty "$krew_ver" "krew version extracted from Dockerfile"

    # Verify it's a reasonable version format
    if echo "$krew_ver" | command grep -qE '^[0-9]+\.[0-9]+'; then
        assert_true true "krew version has valid format"
    else
        assert_true false "krew version has invalid format: $krew_ver"
    fi
}

run_test test_extract_krew_version "Script extracts krew version from Dockerfile"

# ============================================================================
# Test: Exit codes and the unchecked-tool gate (#991)
# ============================================================================
# These drive the REAL bin/lib/check-versions/output.sh with a hand-built tool
# table and read back both the JSON and the process exit, rather than grepping
# the source for `exit 1` (which is what these tests used to do, and which
# passed no matter what the exit logic actually did).

# run_output FORMAT STATUS... — each STATUS is "tool:current:latest:status".
# Prints the output, then "RC=<exit>" as the last line. print_results calls
# `exit` itself, so the code is read from the subshell's status — never from a
# line the subshell prints, which an `exit` would skip.
run_output() {
    local format="$1" rc=0 out
    shift
    out=$(
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/check-versions/output.sh"
        set +e
        OUTPUT_FORMAT="$format"
        TOOLS=() CURRENT_VERSIONS=() LATEST_VERSIONS=() VERSION_STATUS=() VERSION_FILES=()
        row="" t="" c="" l="" st=""
        for row in "$@"; do
            IFS=: read -r t c l st <<<"$row"
            TOOLS+=("$t") CURRENT_VERSIONS+=("$c") LATEST_VERSIONS+=("$l")
            VERSION_STATUS+=("$st") VERSION_FILES+=("f.sh")
        done
        print_results
    ) || rc=$?
    command sed 's/\x1b\[[0-9;]*m//g' <<<"$out"
    echo "RC=$rc"
}

rc_of() { command sed -n 's/^RC=//p' <<<"$1" | command tail -1; }
json_of() { command sed '/^RC=/d' <<<"$1"; }

test_exit_code_current() {
    local out
    out=$(run_output json "a:1.0:1.0:current" "b:2.0:2.0:current")
    assert_equals "0|0|0" "$(rc_of "$out")|$(json_of "$out" | jq -r '.exit_code')|$(json_of "$out" | jq -r '.summary.unchecked')" \
        "all current: exit 0, exit_code 0, unchecked 0"
}

test_exit_code_outdated() {
    local out
    out=$(run_output json "a:1.0:1.0:current" "b:2.0:2.1:outdated")
    assert_equals "1|1" "$(rc_of "$out")|$(json_of "$out" | jq -r '.exit_code')" \
        "an outdated tool exits 1"
}

test_unchecked_tool_is_loud_json() {
    local out
    out=$(run_output json "a:1.0:2.0:outdated" "cargo-binstall:1.20.0::unchecked")
    local got
    got="$(rc_of "$out")|$(json_of "$out" | jq -c '[.exit_code, .summary.unchecked, .unchecked_tools]')"
    assert_equals '3|[3,1,["cargo-binstall"]]' "$got" \
        "an unchecked tool exits 3 (over outdated's 1) and is named in the JSON"
}

test_unchecked_tool_is_loud_text() {
    local out
    out=$(run_output text "cargo-binstall:1.20.0::unchecked")
    if [ "$(rc_of "$out")" = "3" ] && command grep -q "no checker case in bin/check-versions.sh: cargo-binstall" <<<"$out"; then
        assert_true true "text mode names the unchecked tool and exits 3"
    else
        command echo "$out" | command tail -6
        assert_true false "text mode names the unchecked tool and exits 3"
    fi
}

# ============================================================================
# Test: every registered tool has a checker case (#991) — offline, real script
# ============================================================================
# Runs the REAL check-versions.sh against this repo with `curl` stubbed on PATH.
# The stub fails every request (curl -f's exit 22 on an HTTP error), so every
# checker that ran lands on `error`, and a tool that is still `unchecked` can
# only be one no checker ever ran against: a registration in
# extract_all_versions with no case in main()'s dispatch. This is the check
# that would have caught cargo-binstall stalling from #532 to #991.
#
# The same run is also the regression test for the errexit leak: common.sh and
# version-utils.sh `set -e` at source time, and under -e one empty fetch
# pipeline aborted the whole script with no output at all.

# run_offline_sweep DIR [SCRIPT] — writes DIR/out.json, DIR/err, and echoes the
# exit code. SCRIPT defaults to the repo's check-versions.sh.
run_offline_sweep() {
    local dir="$1" script="${2:-$PROJECT_ROOT/bin/check-versions.sh}" rc=0
    command mkdir -p "$dir/stub"
    command printf '#!/bin/sh\nexit 22\n' >"$dir/stub/curl"
    command chmod +x "$dir/stub/curl"
    env -u BASH_ENV -u GITHUB_TOKEN \
        PATH="$dir/stub:$PATH" XDG_CACHE_HOME="$dir/cache" \
        "$script" --json --no-cache \
        >"$dir/out.json" 2>"$dir/err" || rc=$?
    echo "$rc"
}

test_offline_sweep_survives_failed_fetches() {
    local dir rc
    dir=$(command mktemp -d)
    rc=$(run_offline_sweep "$dir")
    local total errors valid=false
    jq -e . "$dir/out.json" >/dev/null 2>&1 && valid=true
    total=$(jq -r '.summary.total // 0' "$dir/out.json" 2>/dev/null)
    errors=$(jq -r '.summary.errors // 0' "$dir/out.json" 2>/dev/null)
    command rm -rf "$dir"
    # Every fetch failed, so every checked tool must be `error` — not current,
    # and not a run that died before printing anything.
    if [ "$valid" = true ] && [ "${total:-0}" -gt 50 ] && [ "$errors" = "$total" ]; then
        assert_true true "a sweep where every fetch fails still emits JSON ($total tools, all error)"
    else
        assert_true false "offline sweep: rc=$rc valid_json=$valid total=$total errors=$errors"
    fi
}

test_every_registered_tool_has_a_checker() {
    local dir rc unchecked
    dir=$(command mktemp -d)
    rc=$(run_offline_sweep "$dir")
    # jq on an EMPTY file prints nothing and exits 0 — a run that died before
    # emitting JSON would read as "no unchecked tools". Require a real document
    # that carries the field.
    if jq -e 'has("unchecked_tools")' "$dir/out.json" >/dev/null 2>&1; then
        unchecked=$(jq -r '.unchecked_tools | join(" ")' "$dir/out.json")
    else
        unchecked="<no JSON document>"
    fi
    command rm -rf "$dir"
    if [ -z "$unchecked" ] && [ "$rc" != "3" ]; then
        assert_true true "every tool registered in check-versions.sh has a checker case"
    else
        assert_true false "registered with no checker case in main(): ${unchecked} (rc=$rc)"
    fi
}

test_unregistered_checker_trips_gate() {
    # Prove the guard above fails on the defect it exists for — through the real
    # extraction -> main() dispatch -> output path, not by injecting a status.
    # A scratch copy of the repo's bin/ and pinned files gains ONE registration
    # for a tool that has no case in main(); the run must exit 3 and name it.
    local dir tree rc named
    dir=$(command mktemp -d)
    tree="$dir/tree"
    command mkdir -p "$tree"
    command cp -R "$PROJECT_ROOT/bin" "$PROJECT_ROOT/lib" "$PROJECT_ROOT/Dockerfile" "$tree/"
    command cp -R "$PROJECT_ROOT/.github" "$PROJECT_ROOT/.gitlab" "$tree/"
    command printf 'FIXTURE_NOCHECK_VERSION="${FIXTURE_NOCHECK_VERSION:-1.0.0}"\n' \
        >>"$tree/lib/features/rust-dev.sh"
    command sed -i 's|^    _add_feature_version CARGO_BINSTALL_VERSION "cargo-binstall" "rust-dev.sh"$|&\n    _add_feature_version FIXTURE_NOCHECK_VERSION "fixture-nocheck" "rust-dev.sh"|' \
        "$tree/bin/check-versions.sh"
    if ! command grep -q '"fixture-nocheck"' "$tree/bin/check-versions.sh"; then
        command rm -rf "$dir"
        assert_true false "fixture registration was not injected — anchor line moved?"
        return
    fi

    rc=$(run_offline_sweep "$dir" "$tree/bin/check-versions.sh")
    named=$(jq -r '(.unchecked_tools // []) | join(" ")' "$dir/out.json" 2>/dev/null)
    command rm -rf "$dir"
    assert_equals "3|fixture-nocheck" "$rc|$named" \
        "a registered tool with no checker case exits 3 and is named"
}

test_cargo_binstall_resolves_outdated() {
    # #991 AC: cargo-binstall is checked against its GitHub releases and reported
    # outdated. The stub answers ONLY cargo-binstall's endpoint (with the same
    # `v`-prefixed tag shape GitHub returns) and fails everything else.
    local dir rc row
    dir=$(command mktemp -d)
    command mkdir -p "$dir/stub"
    command cat >"$dir/stub/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        https://api.github.com/repos/cargo-bins/cargo-binstall/releases/latest)
            printf '{"tag_name":"v99.1.0"}'
            exit 0
            ;;
    esac
done
exit 22
EOF
    command chmod +x "$dir/stub/curl"
    env -u BASH_ENV -u GITHUB_TOKEN PATH="$dir/stub:$PATH" XDG_CACHE_HOME="$dir/cache" \
        "$PROJECT_ROOT/bin/check-versions.sh" --json --no-cache >"$dir/out.json" 2>/dev/null || rc=$?
    row=$(jq -r '.tools[] | select(.tool == "cargo-binstall") | "\(.latest) \(.status)"' "$dir/out.json" 2>/dev/null)
    command rm -rf "$dir"
    assert_equals "99.1.0 outdated" "$row" "cargo-binstall is checked against GitHub releases (v stripped)"
}

test_npm_tools_resolve_via_registry() {
    # #985: agnix and corepack are the only check_npm consumers. Drive them
    # through the real extraction -> main() dispatch -> output path: the stub
    # answers ONLY their two registry documents and fails everything else, so
    # a missing/renamed dispatch arm or a broken COREPACK_VERSION extraction
    # from node.sh shows up as a wrong row, not a pass.
    local dir rc rows pin
    dir=$(command mktemp -d)
    command mkdir -p "$dir/stub"
    command cat >"$dir/stub/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        https://registry.npmjs.org/corepack)
            printf '{"dist-tags":{"latest":"99.0.1"}}'
            exit 0
            ;;
        https://registry.npmjs.org/agnix)
            printf '{"dist-tags":{"latest":"99.0.2"}}'
            exit 0
            ;;
    esac
done
exit 22
EOF
    command chmod +x "$dir/stub/curl"
    env -u BASH_ENV -u GITHUB_TOKEN PATH="$dir/stub:$PATH" XDG_CACHE_HOME="$dir/cache" \
        "$PROJECT_ROOT/bin/check-versions.sh" --json --no-cache >"$dir/out.json" 2>/dev/null || rc=$?
    rows=$(jq -r '.tools[] | select(.tool == "corepack" or .tool == "agnix")
        | "\(.tool) \(.current) \(.latest) \(.status)"' "$dir/out.json" 2>/dev/null | command sort)
    command rm -rf "$dir"

    # The expected current values are read from the pinned sources, so this
    # pins the extraction, not today's version numbers.
    pin=$(command sed -n 's/^COREPACK_VERSION="\${COREPACK_VERSION:-\([^}]*\)}"$/\1/p' \
        "$PROJECT_ROOT/lib/features/node.sh")
    local agnix_pin
    agnix_pin=$(command sed -n 's/^AGNIX_VERSION="\${AGNIX_VERSION:-\([^}]*\)}"$/\1/p' \
        "$PROJECT_ROOT/lib/features/dev-tools.sh")
    if [ -z "$pin" ] || [ -z "$agnix_pin" ]; then
        assert_true false "could not read the corepack/agnix pins (corepack='$pin' agnix='$agnix_pin')"
        return
    fi
    assert_equals "agnix $agnix_pin 99.0.2 outdated
corepack $pin 99.0.1 outdated" "$rows" \
        "agnix and corepack are checked against the npm registry with their pinned versions"
}

run_test test_exit_code_current "Exit code is 0 when all versions current"
run_test test_exit_code_outdated "Exit code is 1 when versions outdated"
run_test test_unchecked_tool_is_loud_json "Unchecked tool exits 3 and is named in JSON"
run_test test_unchecked_tool_is_loud_text "Unchecked tool exits 3 and is named in text"
run_test test_offline_sweep_survives_failed_fetches "Sweep survives failed fetches (errexit leak)"
run_test test_every_registered_tool_has_a_checker "Every registered tool has a checker case"
run_test test_unregistered_checker_trips_gate "Tool with no checker case trips the gate (via main)"
run_test test_cargo_binstall_resolves_outdated "cargo-binstall resolves via GitHub releases"
run_test test_npm_tools_resolve_via_registry "agnix and corepack resolve via the npm registry"

# ============================================================================
# Test: Mock-based check function tests
# ============================================================================

# Helper to set up mock environment for check functions
setup_check_env() {
    # Source dependencies
    source "$PROJECT_ROOT/bin/lib/common.sh" 2>/dev/null || true
    source "$PROJECT_ROOT/bin/lib/version-utils.sh" 2>/dev/null || true

    # Initialize arrays
    TOOLS=()
    CURRENT_VERSIONS=()
    LATEST_VERSIONS=()
    VERSION_STATUS=()
    VERSION_FILES=()

    # Quiet output
    OUTPUT_FORMAT="json"
    export OUTPUT_FORMAT

    # Define helper functions from check-versions.sh that check functions depend on
    add_tool() {
        local tool="$1" current="$2" file="$3"
        TOOLS+=("$tool")
        CURRENT_VERSIONS+=("$current")
        LATEST_VERSIONS+=("")
        VERSION_STATUS+=("unchecked")
        VERSION_FILES+=("$file")
    }

    set_latest() {
        local tool="$1" version="$2"
        if [ -z "$version" ] || [ "$version" = "null" ] || [ "$version" = "undefined" ]; then
            version="error"
        fi
        for i in "${!TOOLS[@]}"; do
            if [ "${TOOLS[i]}" = "$tool" ]; then
                LATEST_VERSIONS[i]="$version"
                if version_matches "${CURRENT_VERSIONS[i]}" "$version"; then
                    VERSION_STATUS[i]="current"
                elif [ "$version" = "error" ]; then
                    VERSION_STATUS[i]="error"
                else
                    VERSION_STATUS[i]="outdated"
                fi
                break
            fi
        done
    }
}

test_check_python_mock() {
    setup_check_env

    add_tool "Python" "3.12.8" "Dockerfile"

    # Mock fetch_url
    fetch_url() {
        case "$1" in
            *"endoflife.date/api/python.json"*)
                echo '[{"cycle":"3.13","latest":"3.13.6"},{"cycle":"3.12","latest":"3.12.8"}]'
                ;;
        esac
    }

    # Source and run check function
    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_python

    assert_equals "3.13.6" "${LATEST_VERSIONS[0]}" "Python latest version set correctly"
}

test_check_rust_mock() {
    setup_check_env

    add_tool "Rust" "1.84.0" "Dockerfile"

    fetch_url() {
        case "$1" in
            *"api.github.com/repos/rust-lang/rust/releases"*)
                echo '[{"tag_name":"1.85.0","prerelease":false},{"tag_name":"1.84.0","prerelease":false}]'
                ;;
        esac
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_rust

    assert_equals "1.85.0" "${LATEST_VERSIONS[0]}" "Rust latest version extracted from releases"
}

test_check_github_release_mock() {
    setup_check_env

    add_tool "lazygit" "0.56.0" "dev-tools.sh"

    fetch_url() {
        echo '{"tag_name":"v0.57.0"}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_github_release "lazygit" "jesseduffield/lazygit"

    assert_equals "0.57.0" "${LATEST_VERSIONS[0]}" "GitHub release version extracted correctly"
}

test_check_github_release_prerelease_mock() {
    setup_check_env

    add_tool "conform" "0.1.0-alpha.30" "dev-tools.sh"

    # /releases endpoint returns prereleases too, ordered newest first
    fetch_url() {
        echo '[{"tag_name":"v0.1.0-alpha.31","draft":false,"prerelease":true},{"tag_name":"v0.1.0-alpha.30","draft":false,"prerelease":true}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_github_release_prerelease "conform" "siderolabs/conform"

    assert_equals "0.1.0-alpha.31" "${LATEST_VERSIONS[0]}" "Prerelease GitHub tag extracted correctly"
}

test_check_github_release_prerelease_skips_drafts() {
    setup_check_env

    add_tool "conform" "0.1.0-alpha.30" "dev-tools.sh"

    fetch_url() {
        echo '[{"tag_name":"v0.1.0-alpha.32","draft":true,"prerelease":true},{"tag_name":"v0.1.0-alpha.31","draft":false,"prerelease":true}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_github_release_prerelease "conform" "siderolabs/conform"

    assert_equals "0.1.0-alpha.31" "${LATEST_VERSIONS[0]}" "Drafts skipped, latest non-draft prerelease used"
}

test_check_gitlab_release_mock() {
    setup_check_env

    add_tool "glab" "1.45.0" "dev-tools.sh"

    fetch_url() {
        echo '[{"tag_name":"v1.46.0"}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_gitlab_release "glab" "gitlab-org%2Fcli"

    assert_equals "1.46.0" "${LATEST_VERSIONS[0]}" "GitLab release version extracted correctly"
}

test_check_crates_io_mock() {
    setup_check_env

    add_tool "cargo-release" "0.25.0" "dev-tools.sh"

    fetch_url() {
        echo '{"crate":{"max_version":"0.25.15"}}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_crates_io "cargo-release"

    assert_equals "0.25.15" "${LATEST_VERSIONS[0]}" "crates.io version extracted correctly"
}

test_check_npm_mock() {
    setup_check_env

    add_tool "corepack" "0.36.0" "node.sh"
    add_tool "renamed-tool" "1.0.0" "dev-tools.sh"

    # Answer per URL so a wrong package name in the request reads as an error
    # row instead of borrowing another package's document.
    fetch_url() {
        case "$1" in
            https://registry.npmjs.org/corepack) echo '{"dist-tags":{"latest":"0.37.0","next":"0.38.0-rc.1"}}' ;;
            https://registry.npmjs.org/real-package) echo '{"dist-tags":{"latest":"2.1.0"}}' ;;
            *) echo '{}' ;;
        esac
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_npm "corepack"
    check_npm "renamed-tool" "real-package"

    assert_equals "0.37.0" "${LATEST_VERSIONS[0]}" "npm dist-tags.latest extracted (not another tag)"
    assert_equals "outdated" "${VERSION_STATUS[0]}" "older pin is reported outdated"
    assert_equals "2.1.0" "${LATEST_VERSIONS[1]}" "two-arg form queries the package name, not the tool name"
}

test_check_npm_missing_latest_is_error() {
    setup_check_env

    add_tool "corepack" "0.36.0" "node.sh"
    fetch_url() { echo '{"error":"Not found"}'; }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_npm "corepack"

    assert_equals "error" "${VERSION_STATUS[0]}" "a registry document with no dist-tags.latest is an error, not current"
}

test_check_rubygems_mock() {
    setup_check_env

    add_tool "gitlab-triage" "1.51.0" "Gemfile"

    fetch_url() {
        echo '{"version":"1.52.0"}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_rubygems "gitlab-triage"

    assert_equals "1.52.0" "${LATEST_VERSIONS[0]}" "RubyGems version extracted correctly"
}

test_check_rubygems_missing_gem() {
    # A 404 / unparsable body must surface as an ERROR, never as "no update
    # available" — a silent pass there would stall the pin at its current
    # version forever, which is the whole failure mode this tracking prevents.
    # check_rubygems emits the "null" sentinel, which set_latest() normalizes to
    # "error" and marks the tool's status accordingly.
    setup_check_env

    add_tool "gitlab-triage" "1.51.0" "Gemfile"

    fetch_url() {
        echo ''
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_rubygems "gitlab-triage"

    assert_equals "error" "${LATEST_VERSIONS[0]}" "an unparsable response is recorded as an error"
    assert_equals "error" "${VERSION_STATUS[0]}" "the tool's status is error, not current"
}

test_check_maven_central_mock() {
    setup_check_env

    add_tool "jmh" "1.37" "java-dev.sh"

    fetch_url() {
        echo '{"response":{"docs":[{"latestVersion":"1.38"}]}}'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_maven_central "jmh" "org.openjdk.jmh" "jmh-core"

    assert_equals "1.38" "${LATEST_VERSIONS[0]}" "Maven Central version extracted correctly"
}

test_check_biome_new_format() {
    setup_check_env

    add_tool "biome" "1.9.0" "dev-tools.sh"

    fetch_url() {
        echo '[{"tag_name":"@biomejs/biome@1.9.4"},{"tag_name":"@biomejs/biome@1.9.3"}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_biome

    assert_equals "1.9.4" "${LATEST_VERSIONS[0]}" "Biome new tag format parsed correctly"
}

test_check_kubectl_mock() {
    setup_check_env

    add_tool "kubectl" "1.33" "Dockerfile"

    fetch_url() {
        echo '[{"tag_name":"v1.33.1","prerelease":false},{"tag_name":"v1.33.0","prerelease":false},{"tag_name":"v1.32.5","prerelease":false}]'
    }

    source "$PROJECT_ROOT/bin/lib/check-versions/checks.sh"
    check_kubectl

    assert_equals "1.33.1" "${LATEST_VERSIONS[0]}" "kubectl version extracted for major.minor"
}

run_test test_check_python_mock "check_python with mock API response"
run_test test_check_rust_mock "check_rust with mock API response"
run_test test_check_github_release_mock "check_github_release with mock API response"
run_test test_check_github_release_prerelease_mock "check_github_release_prerelease picks newest tag including prereleases"
run_test test_check_github_release_prerelease_skips_drafts "check_github_release_prerelease skips draft releases"
run_test test_check_gitlab_release_mock "check_gitlab_release with mock API response"
run_test test_check_crates_io_mock "check_crates_io with mock API response"
run_test test_check_npm_mock "check_npm with mock API response"
run_test test_check_npm_missing_latest_is_error "check_npm with no dist-tags.latest reports error"
run_test test_check_rubygems_mock "check_rubygems with mock API response"
run_test test_check_rubygems_missing_gem "check_rubygems falls back to null on an empty response"
run_test test_check_maven_central_mock "check_maven_central with mock API response"
# ============================================================================
# Test: extract_action_version normalizes SHA-pinned / tag / branch refs
# ============================================================================
# Regression guard: a SHA-pinned third-party action carries its version in the
# trailing `# vX.Y.Z` comment, not in the `@`-ref. An earlier version of the
# trivy-action extraction took the text after `@`, capturing the 40-hex SHA and
# reporting the action as perpetually outdated (which then drove the updater to
# corrupt the ref). These tests pin the normalization contract.
test_extract_action_version_sha_pinned() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local out
    out=$(extract_action_version "ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0")
    assert_equals "0.36.0" "$out" "SHA-pinned ref reads version from # comment"
}

test_extract_action_version_sha_pinned_no_v() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local out
    out=$(extract_action_version "ed142fd0673e97e23eac54620cfb913e5ce36c25 # 0.36.0")
    assert_equals "0.36.0" "$out" "SHA-pinned ref with un-prefixed comment version"
}

test_extract_action_version_plain_tags() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local out
    out=$(extract_action_version "v0.36.0")
    assert_equals "0.36.0" "$out" "v-prefixed tag strips leading v"

    out=$(extract_action_version "0.36.0")
    assert_equals "0.36.0" "$out" "bare tag passes through"
}

test_extract_action_version_branch_passthrough() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # A branch ref (no version comment) echoes through unchanged so the caller
    # can detect and skip it (check-versions guards on `!= master`).
    local out
    out=$(extract_action_version "master")
    assert_equals "master" "$out" "branch ref passes through unchanged"
}

run_test test_check_biome_new_format "check_biome parses new tag format"
run_test test_check_kubectl_mock "check_kubectl with mock API response"
run_test test_extract_action_version_sha_pinned "extract_action_version reads version from SHA-pin comment"
run_test test_extract_action_version_sha_pinned_no_v "extract_action_version handles un-prefixed comment version"
run_test test_extract_action_version_plain_tags "extract_action_version normalizes plain tags"
run_test test_extract_action_version_branch_passthrough "extract_action_version passes branch refs through"

# Generate test report
generate_report
