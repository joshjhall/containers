#!/usr/bin/env bash
# Unit tests for update-versions' luggage catalog-failure propagation: every
# luggage-installed tool's updater arm must turn a failed
# `luggage catalog add-version` into RC_UPDATE_FAILED and exit 3.
# Split from tests/unit/bin/update-versions.sh (#1512). Each later luggage port
# (python, ruby, ...) adds its catalog-failure test here, not to the main suite.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Update Versions Luggage Catalog Tests"

# ============================================================================
# Test: a failed update_luggage_catalog propagates RC_UPDATE_FAILED / exit 3
# ============================================================================
# The Rust arm does `update_luggage_catalog "rust" "$latest" || return
# "$RC_UPDATE_FAILED"`, mirroring pin_action's propagation — but only pin_action's
# was covered. This is the half-updated-tree case that matters most: a Dockerfile
# ARG bumped without its vendored catalog entry (issue #506) ships a build that
# cannot succeed, so it must be fatal (exit 3) rather than a tolerated skip.
#
# Failure is forced with a stub binary that exits 1, NOT by pointing LUGGAGE_BIN
# at a missing path — the latter would exit 127 from a failed exec and pass for
# the wrong reason, proving nothing about the intended propagation.
_write_luggage_failure_fixture() {
    local test_dir="$1"

    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG RUST_VERSION=1.90.0
EOF
    command cat >"$test_dir/lib/features/rust.sh" <<'EOF'
#!/bin/bash
RUST_VERSION="${RUST_VERSION:-1.90.0}"
EOF

    # Stub luggage: always fails, as a real `catalog add-version` would against
    # a missing or unwritable vendored catalog.
    command cat >"$test_dir/luggage-stub" <<'EOF'
#!/bin/bash
echo "stub luggage: catalog add-version failed" >&2
exit 1
EOF
    command chmod +x "$test_dir/luggage-stub"
}

test_luggage_catalog_failure_exits_three() {
    local test_dir
    test_dir=$(mktemp -d)
    _write_luggage_failure_fixture "$test_dir"

    local ok=true

    # Layer 1: update_version() itself returns RC_UPDATE_FAILED.
    local rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

        # shellcheck disable=SC2030,SC2034 # consumed by update_version() from the sourced module
        PROJECT_ROOT="$test_dir"
        # shellcheck disable=SC2030,SC2034 # ditto
        DRY_RUN=false
        # shellcheck disable=SC2030,SC2034 # ditto
        LUGGAGE_BIN="$test_dir/luggage-stub"

        update_version "Rust" "1.90.0" "1.91.0" "Dockerfile" >/dev/null 2>&1
    ) || rc=$?

    # RC_UPDATE_FAILED is 4; re-read it rather than hardcoding.
    local expected_rc
    expected_rc=$(
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        printf '%s' "$RC_UPDATE_FAILED"
    )
    [ "$rc" -eq "$expected_rc" ] || {
        echo "    update_version: expected RC_UPDATE_FAILED ($expected_rc), got $rc"
        ok=false
    }

    # Layer 2: the script surfaces that as the fatal exit 3, not the tolerated 2.
    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "Rust", "current": "1.90.0", "latest": "1.91.0", "file": "Dockerfile", "status": "outdated"}
  ]
}
EOF

    local script_rc=0
    (
        cd "$test_dir" || exit 1
        # shellcheck disable=SC2031 # separate subshell from the one above
        PROJECT_ROOT_OVERRIDE="$test_dir" LUGGAGE_BIN="$test_dir/luggage-stub" \
            "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json >/dev/null 2>&1
    ) || script_rc=$?

    [ "$script_rc" -eq 3 ] || {
        echo "    update-versions.sh: expected exit 3, got $script_rc"
        ok=false
    }

    command rm -rf "$test_dir"
    assert_true "$ok" "A failed luggage catalog update returns RC_UPDATE_FAILED and exits 3"
}

# ============================================================================
# Test: the Go arm propagates a failed catalog update the same way (#811)
# ============================================================================
# golang.sh installs via luggage since #811, so the Go arm gained the same
# `update_luggage_catalog "go" "$latest" || return "$RC_UPDATE_FAILED"` line as
# Rust. A Go ARG bumped without its vendored catalog entry is the same
# unbuildable half-update, so it must be fatal too. Same stub-failure shape as
# the Rust test above, so the failure is the propagation under test and not an
# exec error (127) that would pass for the wrong reason.
test_go_luggage_catalog_failure_exits_three() {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG GO_VERSION=1.27.2
EOF
    command cat >"$test_dir/lib/features/golang.sh" <<'EOF'
#!/bin/bash
GO_VERSION="${GO_VERSION:-1.27.2}"
EOF
    # The stub records its argv before failing, so the test can tell a call
    # for go@<latest> from a copy-pasted "rust" arm or a $current argument —
    # both of which fail identically and would otherwise pass.
    command cat >"$test_dir/luggage-stub" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/luggage-argv.log"
echo "stub luggage: catalog add-version failed" >&2
exit 1
EOF
    command chmod +x "$test_dir/luggage-stub"

    local ok=true rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

        # shellcheck disable=SC2030,SC2034 # consumed by update_version() from the sourced module
        PROJECT_ROOT="$test_dir"
        # shellcheck disable=SC2030,SC2034 # ditto
        DRY_RUN=false
        # shellcheck disable=SC2030,SC2034 # ditto
        LUGGAGE_BIN="$test_dir/luggage-stub"

        update_version "Go" "1.27.2" "1.27.3" "Dockerfile" >/dev/null 2>&1
    ) || rc=$?

    # The catalog call targets go at the NEW version, exactly.
    command grep -qE '^catalog add-version go@1\.27\.3( |$)' "$test_dir/luggage-argv.log" 2>/dev/null || {
        echo "    expected 'catalog add-version go@1.27.3', got: $(command cat "$test_dir/luggage-argv.log" 2>/dev/null || echo '<no call>')"
        ok=false
    }

    local expected_rc
    expected_rc=$(
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        printf '%s' "$RC_UPDATE_FAILED"
    )
    [ "$rc" -eq "$expected_rc" ] || {
        echo "    update_version Go: expected RC_UPDATE_FAILED ($expected_rc), got $rc"
        ok=false
    }

    # The pin edits still ran before the catalog step failed — so a non-fatal
    # catalog failure would leave exactly this half-updated tree behind.
    command grep -q '^ARG GO_VERSION=1.27.3$' "$test_dir/Dockerfile" || {
        echo "    expected the Dockerfile ARG bumped before the catalog step"
        ok=false
    }

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "Go", "current": "1.27.2", "latest": "1.27.3", "file": "Dockerfile", "status": "outdated"}
  ]
}
EOF
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG GO_VERSION=1.27.2
EOF
    local script_rc=0
    (
        cd "$test_dir" || exit 1
        # shellcheck disable=SC2031 # separate subshell from the one above
        PROJECT_ROOT_OVERRIDE="$test_dir" LUGGAGE_BIN="$test_dir/luggage-stub" \
            "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json >/dev/null 2>&1
    ) || script_rc=$?
    [ "$script_rc" -eq 3 ] || {
        echo "    update-versions.sh Go: expected exit 3, got $script_rc"
        ok=false
    }

    command rm -rf "$test_dir"
    assert_true "$ok" "A failed Go luggage catalog update returns RC_UPDATE_FAILED and exits 3"
}

# ============================================================================
# Test: the Node.js arm propagates a failed catalog update the same way (#812)
# ============================================================================
# node.sh installs via luggage since #812, so the Node.js arm gained the same
# `update_luggage_catalog "node" "$latest" || return "$RC_UPDATE_FAILED"` line as
# Go and Rust. A Node ARG bumped without its vendored catalog entry is the same
# unbuildable half-update, so it must be fatal too. Same stub-failure shape as
# the Rust test above, so the failure is the propagation under test and not an
# exec error (127) that would pass for the wrong reason.
test_node_luggage_catalog_failure_exits_three() {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG NODE_VERSION=22
EOF
    command cat >"$test_dir/lib/features/node.sh" <<'EOF'
#!/bin/bash
NODE_VERSION="${NODE_VERSION:-22}"
EOF
    # The stub records its argv before failing, so the test can tell a call
    # for node@<latest> from a copy-pasted "go" arm or a $current argument —
    # both of which fail identically and would otherwise pass.
    command cat >"$test_dir/luggage-stub" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/luggage-argv.log"
echo "stub luggage: catalog add-version failed" >&2
exit 1
EOF
    command chmod +x "$test_dir/luggage-stub"

    local ok=true rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

        # shellcheck disable=SC2030,SC2034 # consumed by update_version() from the sourced module
        PROJECT_ROOT="$test_dir"
        # shellcheck disable=SC2030,SC2034 # ditto
        DRY_RUN=false
        # shellcheck disable=SC2030,SC2034 # ditto
        LUGGAGE_BIN="$test_dir/luggage-stub"

        update_version "Node.js" "22" "22.23.5" "Dockerfile" >/dev/null 2>&1
    ) || rc=$?

    # The catalog call targets node at the NEW (exact) version, exactly.
    command grep -qE '^catalog add-version node@22\.23\.5( |$)' "$test_dir/luggage-argv.log" 2>/dev/null || {
        echo "    expected 'catalog add-version node@22.23.5', got: $(command cat "$test_dir/luggage-argv.log" 2>/dev/null || echo '<no call>')"
        ok=false
    }

    local expected_rc
    expected_rc=$(
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        printf '%s' "$RC_UPDATE_FAILED"
    )
    [ "$rc" -eq "$expected_rc" ] || {
        echo "    update_version Node.js: expected RC_UPDATE_FAILED ($expected_rc), got $rc"
        ok=false
    }

    # The pin edits still ran before the catalog step failed — so a non-fatal
    # catalog failure would leave exactly this half-updated tree behind.
    command grep -q '^ARG NODE_VERSION=22.23.5$' "$test_dir/Dockerfile" || {
        echo "    expected the Dockerfile ARG bumped before the catalog step"
        ok=false
    }

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "Node.js", "current": "22", "latest": "22.23.5", "file": "Dockerfile", "status": "outdated"}
  ]
}
EOF
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG NODE_VERSION=22
EOF
    local script_rc=0
    (
        cd "$test_dir" || exit 1
        # shellcheck disable=SC2031 # separate subshell from the one above
        PROJECT_ROOT_OVERRIDE="$test_dir" LUGGAGE_BIN="$test_dir/luggage-stub" \
            "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json >/dev/null 2>&1
    ) || script_rc=$?
    [ "$script_rc" -eq 3 ] || {
        echo "    update-versions.sh Node.js: expected exit 3, got $script_rc"
        ok=false
    }

    command rm -rf "$test_dir"
    assert_true "$ok" "A failed Node.js luggage catalog update returns RC_UPDATE_FAILED and exits 3"
}

run_test test_luggage_catalog_failure_exits_three "Failed luggage catalog update returns RC_UPDATE_FAILED and exits 3"
run_test test_go_luggage_catalog_failure_exits_three "Failed Go luggage catalog update returns RC_UPDATE_FAILED and exits 3"
run_test test_node_luggage_catalog_failure_exits_three "Failed Node.js luggage catalog update returns RC_UPDATE_FAILED and exits 3"

# Generate report
generate_report
