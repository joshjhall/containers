#!/usr/bin/env bash
# Unit tests for librarian_boot_plugins — the boot path's install+verify entry
# point (issue #944)
#
# WHAT THIS COVERS AND WHY IT IS SEPARATE
# ---------------------------------------
# #777 added the capability verifier (librarian_verify_plugins) and wired it
# into `claude-plugins-repair repair`. The BOOT path did not call it: it ran
# `librarian_install_plugins || true` and stopped there. That is an install exit
# code, and librarian_install_plugins absorbs every per-plugin failure while
# librarian_marketplace_registered's grep prints "✓ Marketplace registered" for
# a registry file naming librarian whose plugins are absent or inert. So a boot
# that installed nothing still printed only checkmarks — the #777 false-✓,
# reachable at boot. #944 introduced librarian_boot_plugins to close it.
#
# The verification cannot be asserted by grepping claude-setup: a source-text
# pin cannot distinguish a call that verifies from one that does not (this
# repo's "grep pin is not behavioral coverage" lesson). claude-setup itself is
# a 1271-line script that cannot run in a unit test (auth, MCP, jq, git remote
# scans), which is exactly why the behavior lives in a library function — so it
# can be EXECUTED here.
#
# HOW THESE TESTS WORK
# --------------------
# Same harness shape as test_claude_plugins_repair.sh: a stub `claude` as a real
# file first on PATH, driven by files under $MOCK_STATE, with CLAUDE_PLUGIN_LIB
# pointed at the real library, LIBRARIAN_DIR_TEST_OVERRIDE at a fixture dir, and
# HOME at a fake home holding known_marketplaces.json.
#
# Each test runs a small DRIVER script in its own bash process. The driver
# sources the library under `set -euo pipefail` — the boot shell's options —
# calls librarian_boot_plugins, and echoes both its return code and a trailing
# marker. The marker is what proves the call is survivable: if the function ever
# exits or trips `set -e`, the marker never prints.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

init_test_framework

test_suite "librarian boot path Tests"

PLUGIN_LIB="$PROJECT_ROOT/lib/features/lib/claude/claude-plugin-lib.sh"
CLAUDE_SETUP="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-librarian-boot-$unique_id"

    export FAKE_HOME="$TEST_TEMP_DIR/home"
    export STUB_BIN="$TEST_TEMP_DIR/bin"
    export MOCK_STATE="$TEST_TEMP_DIR/mock"
    export FAKE_LIBRARIAN="$TEST_TEMP_DIR/opt/librarian"

    mkdir -p "$FAKE_HOME/.claude/plugins" "$STUB_BIN" "$MOCK_STATE" "$FAKE_LIBRARIAN"

    # Default: marketplace known, all three plugins enabled and fully
    # discovered. Individual tests overwrite these. Status is per plugin so
    # installing one does not flip the others to "already installed".
    _set_all_status "enabled"
    echo "0" >"$MOCK_STATE/install_fails"
    _write_marketplaces_with_librarian
    _write_details "dev-core" 21 6 0
    _write_details "review-audit" 12 10 0
    _write_details "workflow" 10 3 2

    _install_claude_stub
    _install_driver
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR FAKE_HOME STUB_BIN MOCK_STATE FAKE_LIBRARIAN 2>/dev/null || true
}

# --- fixture writers -------------------------------------------------------

_set_all_status() {
    local state="$1" p
    for p in dev-core review-audit workflow; do
        echo "$state" >"$MOCK_STATE/status-$p"
    done
}

# The registry file whose librarian entry the observed failure deleted, while
# leaving the two GitHub-sourced marketplaces intact. Its presence is what
# makes librarian_marketplace_registered's grep say "✓" — the fast path whose
# weakness this suite exists to cover.
_write_marketplaces_with_librarian() {
    command cat >"$FAKE_HOME/.claude/plugins/known_marketplaces.json" <<'JSON'
{
  "claude-plugins-official": { "source": "anthropics/claude-plugins-official" },
  "librarian": { "source": "/opt/librarian" }
}
JSON
}

# Write the `claude plugin details` blob for one plugin, in the real CLI's
# "Component inventory" shape.
_write_details() {
    local plugin="$1" skills="$2" agents="$3" hooks="$4"
    command cat >"$MOCK_STATE/details-$plugin" <<EOF
$plugin 0.13.0
  Description: Test fixture for $plugin
  Source: $plugin@librarian

Component inventory
  Skills ($skills)  alpha, beta, gamma
  Agents ($agents)  one, two
  Hooks ($hooks)  Notification, PreToolUse  (harness-only — no model context cost)
  MCP servers (0)
  LSP servers (0)
EOF
}

_install_claude_stub() {
    command cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$MOCK_STATE/calls"

case "$1 $2" in
    "plugin list")
        for p in dev-core review-audit workflow; do
            status=$(command cat "$MOCK_STATE/status-$p" 2>/dev/null || echo absent)
            [ "$status" = "absent" ] && continue
            printf '  ❯ %s@librarian\n' "$p"
            printf '    Version: 0.13.0\n'
            [ "$status" = "disabled" ] && printf '    Status: ✘ disabled\n'
        done
        exit 0
        ;;
    "plugin details")
        name="${3%%@*}"
        if [ -f "$MOCK_STATE/details-$name" ]; then
            command cat "$MOCK_STATE/details-$name"
            exit 0
        fi
        echo "plugin not found: $3" >&2
        exit 1
        ;;
    "plugin install")
        if [ "$(command cat "$MOCK_STATE/install_fails")" = "1" ]; then
            echo "install exploded" >&2
            exit 1
        fi
        echo "enabled" >"$MOCK_STATE/status-${3%%@*}"
        exit 0
        ;;
    "plugin enable")
        echo "enabled" >"$MOCK_STATE/status-${3%%@*}"
        exit 0
        ;;
    "plugin marketplace")
        exit 0
        ;;
esac
exit 0
STUB
    chmod 755 "$STUB_BIN/claude"
}

# The driver reproduces the boot shell: `set -euo pipefail`, source the library,
# call the function the way claude-setup calls it, then print a marker.
#
# `|| true` and the trailing marker mirror claude-setup's own call site, so a
# regression that makes the function fatal under `set -e` shows up here as a
# missing BOOT_SURVIVED line rather than as a passing test.
_install_driver() {
    command cat >"$TEST_TEMP_DIR/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_LIB"

rc=0
if [ -d "$LIBRARIAN_DIR" ]; then
    librarian_boot_plugins || rc=$?
else
    echo "Librarian marketplace not found at $LIBRARIAN_DIR — skipping librarian plugins"
fi
echo "BOOT_RC=$rc"
echo "BOOT_SURVIVED"
DRIVER
    chmod 755 "$TEST_TEMP_DIR/driver.sh"
}

# Run the driver under the stubbed environment. Echoes combined output.
# BASH_ENV is cleared because /etc/bash_env rebuilds PATH on non-interactive
# bash, which would put the real `claude` ahead of the stub.
_run_boot() {
    env -u BASH_ENV \
        PATH="$STUB_BIN:$PATH" \
        HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" \
        CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        LIBRARIAN_DIR_TEST_OVERRIDE="${LIBRARIAN_OVERRIDE:-$FAKE_LIBRARIAN}" \
        ENABLED_FEATURES_FILE="/nonexistent-enabled-features" \
        CLAUDE_LIBRARIAN_PLUGINS="${PLUGINS_OVERRIDE-dev-core,review-audit,workflow}" \
        CLAUDE_DISABLED_PLUGINS="${DENY_OVERRIDE:-}" \
        CLAUDE_SETUP_RETRY_DELAY=0 \
        bash "$TEST_TEMP_DIR/driver.sh" 2>&1
}

# ============================================================================
# The #944 regression: boot must not report success on an inert install
# ============================================================================

test_boot_fails_when_components_not_discovered() {
    # The exact false-✓ shape. Everything the OLD boot path looked at is
    # healthy: the registry names librarian (so the grep says "✓ Marketplace
    # registered"), every plugin lists as enabled (so the install loop prints
    # "✓ ... already installed"), and nothing returns non-zero. Only
    # `claude plugin details` reveals that workflow exposes no hooks.
    _write_details "workflow" 10 3 0

    local output
    output=$(_run_boot)

    assert_contains "$output" "BOOT_RC=1" \
        "boot returns 1 when a plugin does not expose its components"
    assert_contains "$output" "✗ workflow" \
        "boot names the plugin that failed verification"
    assert_contains "$output" "claude-plugins-repair repair" \
        "boot points at the remedy"
    # The discriminating half: the install half really did report success, so a
    # test that only checked for the absence of "✓" would pass for the wrong
    # reason. Verification is what produced the failure.
    assert_contains "$output" "✓ Marketplace registered" \
        "the marketplace grep still reported success (this is the false-✓ input)"
}

test_boot_fails_when_details_unreadable() {
    # A plugin whose details cannot be read at all — the stub's `plugin details`
    # exits 1 with no fixture file. Distinct from a zero count: it is the
    # registration/CLI failure mode rather than a packaging one.
    command rm -f "$MOCK_STATE/details-dev-core"

    local output
    output=$(_run_boot)

    assert_contains "$output" "BOOT_RC=1" \
        "boot returns 1 when a plugin's details cannot be read"
    assert_contains "$output" "could not read plugin details" \
        "boot reports the unreadable-details cause"
}

test_boot_verifies_after_a_successful_install() {
    # Plugins absent, install succeeds, but the freshly installed plugin still
    # exposes nothing. This is the case librarian_install_plugins' own exit code
    # can never catch: it prints "✓ dev-core installed" and returns 0.
    _set_all_status "absent"
    _write_details "dev-core" 0 6 0

    local output
    output=$(_run_boot)

    assert_contains "$output" "✓ dev-core installed" \
        "the install half reported success"
    assert_contains "$output" "BOOT_RC=1" \
        "verification still fails the boot despite the successful install"
    assert_contains "$output" "no skills discovered" \
        "boot reports zero skills on the newly installed plugin"
}

test_boot_reports_every_failing_plugin() {
    # One complete report, not a stop at the first failure — the operator
    # should not have to re-run to discover the second problem.
    _write_details "dev-core" 21 0 0
    _write_details "workflow" 10 3 0

    local output
    output=$(_run_boot)

    assert_contains "$output" "✗ dev-core" "first failing plugin reported"
    assert_contains "$output" "✗ workflow" "second failing plugin reported"
    assert_contains "$output" "✓ review-audit" "the healthy plugin still reported as healthy"
    assert_contains "$output" "BOOT_RC=1" "overall boot still fails"
}

# ============================================================================
# Loud but never fatal
# ============================================================================

test_verification_failure_does_not_abort_boot() {
    # The headline severity contract. claude-setup runs under `set -e`; one
    # inert plugin must not wedge the container. The driver's trailing marker
    # is only reached if the function returned rather than exiting.
    _write_details "workflow" 10 3 0

    local output
    output=$(_run_boot)

    assert_contains "$output" "BOOT_SURVIVED" \
        "boot continues past a verification failure under set -e"
}

test_missing_librarian_dir_is_a_skip_not_a_failure() {
    # An image built without the librarian clone is a valid configuration, so
    # at boot this is a skip — the asymmetry with claude-plugins-repair, which
    # exits 3 on the same condition.
    LIBRARIAN_OVERRIDE="$TEST_TEMP_DIR/nonexistent-librarian"
    export LIBRARIAN_OVERRIDE

    local output
    output=$(_run_boot)
    unset LIBRARIAN_OVERRIDE

    assert_contains "$output" "skipping librarian plugins" \
        "a missing librarian dir is reported as a skip"
    assert_contains "$output" "BOOT_RC=0" \
        "the skip branch is not a failure"
    assert_contains "$output" "BOOT_SURVIVED" \
        "boot continues past a missing librarian dir"
    assert_not_contains "$output" "Verifying component discovery" \
        "no verification is attempted when there is nothing installed"
}

test_boot_returns_2_when_librarian_dir_absent() {
    # The gate above normally prevents this, but the return code must still
    # distinguish "misconfigured" from "verification failed" for any caller
    # that invokes the function directly (claude-plugins-repair relies on the
    # same distinction being available).
    command cat >"$TEST_TEMP_DIR/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_LIB"
rc=0
librarian_boot_plugins || rc=$?
echo "BOOT_RC=$rc"
echo "BOOT_SURVIVED"
DRIVER
    chmod 755 "$TEST_TEMP_DIR/driver.sh"
    LIBRARIAN_OVERRIDE="$TEST_TEMP_DIR/nonexistent-librarian"
    export LIBRARIAN_OVERRIDE

    local output
    output=$(_run_boot)
    unset LIBRARIAN_OVERRIDE

    assert_contains "$output" "BOOT_RC=2" \
        "a missing librarian dir returns 2, distinct from a verification failure (1)"
    assert_not_contains "$output" "claude-plugins-repair repair" \
        "a missing librarian dir does not suggest a repair — nothing to repair"
}

# ============================================================================
# Healthy and benign paths
# ============================================================================

test_boot_succeeds_on_a_healthy_host() {
    local output
    output=$(_run_boot)

    assert_contains "$output" "BOOT_RC=0" "a healthy host boots clean"
    assert_contains "$output" "Verifying component discovery" \
        "boot announces the verification step"
    assert_contains "$output" "✓ workflow — Skills (10), Agents (3), Hooks (2)" \
        "boot reports the discovered component counts"
    assert_not_contains "$output" "claude-plugins-repair repair" \
        "no remedy is suggested when nothing is wrong"
}

test_empty_plugin_list_is_not_a_failure() {
    # CLAUDE_LIBRARIAN_PLUGINS deliberately set to empty: the operator wants no
    # librarian plugins. Verification must not invent a failure from that.
    PLUGINS_OVERRIDE=""
    export PLUGINS_OVERRIDE

    local output
    output=$(_run_boot)
    unset PLUGINS_OVERRIDE

    assert_contains "$output" "BOOT_RC=0" "an empty plugin list boots clean"
    assert_not_contains "$output" "✗" "no plugin is reported as failing"
}

test_denied_plugin_is_not_a_verification_failure() {
    # CLAUDE_DISABLED_PLUGINS is the operator's own kill-switch (#789). A denied
    # plugin is absent on purpose, so verifying it would fail the boot for a
    # deliberate choice. Its details fixture is removed so that verifying it
    # WOULD fail — the assertion is only meaningful because of that.
    command rm -f "$MOCK_STATE/details-workflow"
    echo "absent" >"$MOCK_STATE/status-workflow"
    DENY_OVERRIDE="workflow"
    export DENY_OVERRIDE

    local output
    output=$(_run_boot)
    unset DENY_OVERRIDE

    assert_contains "$output" "BOOT_RC=0" \
        "a denied plugin does not fail the boot"
    assert_contains "$output" "⊘ workflow" \
        "the denied plugin is still reported as denied"
    assert_not_contains "$output" "✗ workflow" \
        "the denied plugin is not verified"
}

# ============================================================================
# Wiring: the boot path calls the verifying entry point
# ============================================================================
# Source-text assertions, and they are NOT the coverage — the behavioral tests
# above are. These exist only to catch claude-setup silently reverting to the
# install-only call, which no test of the library alone could see.

test_claude_setup_calls_the_verifying_entry_point() {
    assert_file_contains "$CLAUDE_SETUP" 'librarian_boot_plugins' \
        "claude-setup runs the install+verify boot path"
    # The discriminating half: a bare librarian_install_plugins call is exactly
    # the #944 regression, and it would coexist happily with the line above.
    local bare_install
    bare_install=$(command grep -nE '^\s*librarian_install_plugins' "$CLAUDE_SETUP" || true)
    assert_empty "$bare_install" \
        "claude-setup does not call librarian_install_plugins without verifying"
}

test_boot_entry_point_verifies_discovery() {
    # The library must not grow a boot path that skips the verifier.
    assert_file_contains "$PLUGIN_LIB" 'librarian_boot_plugins()' \
        "the library defines the boot entry point"
    local body
    body=$(command sed -n '/^librarian_boot_plugins()/,/^}/p' "$PLUGIN_LIB")
    assert_contains "$body" "librarian_install_plugins" \
        "the boot entry point installs"
    assert_contains "$body" "librarian_verify_plugins" \
        "the boot entry point verifies component discovery"
}

test_marketplace_grep_records_its_fast_path_role() {
    # AC3: the grep predicate stays a grep, but its role as a fast path backed
    # by a real downstream verification must be a recorded decision rather than
    # a leftover.
    local comment
    comment=$(command sed -n '/^# librarian_marketplace_registered/,/^librarian_marketplace_registered()/p' "$PLUGIN_LIB")
    assert_contains "$comment" "944" \
        "the predicate's comment records the #944 decision"
    assert_contains "$comment" "librarian_boot_plugins" \
        "the comment names the downstream verification that backs the fast path"
}

# ============================================================================
# Run
# ============================================================================

run_test test_boot_fails_when_components_not_discovered "boot: an inert install fails verification (#944)"
run_test test_boot_fails_when_details_unreadable "boot: unreadable plugin details fails verification"
run_test test_boot_verifies_after_a_successful_install "boot: verifies what it just installed"
run_test test_boot_reports_every_failing_plugin "boot: reports every failing plugin, not just the first"
run_test test_verification_failure_does_not_abort_boot "severity: a verification failure is loud but not fatal"
run_test test_missing_librarian_dir_is_a_skip_not_a_failure "severity: missing librarian dir is a skip at boot"
run_test test_boot_returns_2_when_librarian_dir_absent "severity: missing librarian dir returns 2, not 1"
run_test test_boot_succeeds_on_a_healthy_host "boot: healthy host exits 0 with component counts"
run_test test_empty_plugin_list_is_not_a_failure "boot: an empty plugin list is not a failure"
run_test test_denied_plugin_is_not_a_verification_failure "boot: honors CLAUDE_DISABLED_PLUGINS (#789)"
run_test test_claude_setup_calls_the_verifying_entry_point "wiring: claude-setup calls the verifying entry point"
run_test test_boot_entry_point_verifies_discovery "wiring: the boot entry point installs AND verifies"
run_test test_marketplace_grep_records_its_fast_path_role "wiring: the grep's fast-path role is recorded (AC3)"

# Generate test report. This is deliberately the LAST command: a suite's exit
# status is its final command's, so anything after it can fake a failure (or
# mask one) independently of the assertions above.
generate_report
