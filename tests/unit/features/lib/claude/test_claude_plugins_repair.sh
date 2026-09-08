#!/usr/bin/env bash
# Unit tests for claude-plugins-repair (issue #777)
#
# claude-plugins-repair is the on-demand trigger for the librarian repair that
# claude-setup already performs at boot. A Claude Code update inside a running
# container was observed to silently de-register the librarian marketplace and
# uninstall all three plugins; every /workflow:*, /dev-core:* and
# /review-audit:* skill then vanished mid-session with no error anywhere.
#
# HOW THESE TESTS WORK
# --------------------
# The script is EXECUTED, not grepped. Each test runs the real file with:
#   - a stub `claude` first on PATH, whose behavior is driven by files in a
#     scratch dir (so a subprocess can change what the next call returns),
#   - CLAUDE_PLUGIN_LIB pointing at the real library,
#   - LIBRARIAN_DIR_TEST_OVERRIDE pointing at a fixture directory (the
#     production LIBRARIAN_DIR is a fixed literal and NOT env-settable),
#   - HOME pointing at a fake home holding known_marketplaces.json.
#
# That matters because the failures this script exists to catch are all
# BEHAVIORAL: a repair that exits 0 having done nothing, or an install that
# succeeds while the plugin exposes no components. A source-text assertion
# cannot distinguish those from the real thing (see the repo's
# "grep pin is not behavioral coverage" lesson).
#
# The `claude` stub must be a real file on PATH rather than a shell function:
# the script under test runs in its own bash process, which does not inherit
# functions from this one.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

init_test_framework

test_suite "claude-plugins-repair Tests"

REPAIR="$PROJECT_ROOT/lib/features/lib/claude/claude-plugins-repair"
PLUGIN_LIB="$PROJECT_ROOT/lib/features/lib/claude/claude-plugin-lib.sh"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-claude-plugins-repair-$unique_id"

    export FAKE_HOME="$TEST_TEMP_DIR/home"
    export STUB_BIN="$TEST_TEMP_DIR/bin"
    export MOCK_STATE="$TEST_TEMP_DIR/mock"
    export FAKE_LIBRARIAN="$TEST_TEMP_DIR/opt/librarian"

    mkdir -p "$FAKE_HOME/.claude/plugins" "$STUB_BIN" "$MOCK_STATE" "$FAKE_LIBRARIAN"

    # Default mock state: marketplace known, all three plugins enabled and
    # fully discovered. Individual tests overwrite these.
    #
    # Status is tracked PER PLUGIN (status-<name>), not globally. A single
    # shared flag made installing one plugin flip the other two to "already
    # installed", which silently turned a three-plugin assertion into a
    # one-plugin one — the mock passing for the wrong reason.
    _set_all_status "enabled"
    echo "0" >"$MOCK_STATE/install_fails"
    _write_marketplaces_with_librarian
    _write_details "dev-core" 21 6 0
    _write_details "review-audit" 12 10 0
    _write_details "workflow" 10 3 2

    _install_claude_stub
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR FAKE_HOME STUB_BIN MOCK_STATE FAKE_LIBRARIAN 2>/dev/null || true
}

# --- fixture writers -------------------------------------------------------

# Set every plugin's mocked state at once: enabled | disabled | absent.
_set_all_status() {
    local state="$1" p
    for p in dev-core review-audit workflow; do
        echo "$state" >"$MOCK_STATE/status-$p"
    done
}

# The registry file whose librarian entry the observed failure deleted, while
# leaving the two GitHub-sourced marketplaces intact.
_write_marketplaces_with_librarian() {
    command cat >"$FAKE_HOME/.claude/plugins/known_marketplaces.json" <<'JSON'
{
  "claude-plugins-official": { "source": "anthropics/claude-plugins-official" },
  "librarian": { "source": "/opt/librarian" }
}
JSON
}

_write_marketplaces_without_librarian() {
    command cat >"$FAKE_HOME/.claude/plugins/known_marketplaces.json" <<'JSON'
{
  "claude-plugins-official": { "source": "anthropics/claude-plugins-official" }
}
JSON
}

# Write the `claude plugin details` blob for one plugin, in the real CLI's
# "Component inventory" shape.
_write_details() {
    local plugin="$1" skills="$2" agents="$3" hooks="$4"
    command cat >"$MOCK_STATE/details-$plugin" <<EOF
$plugin 0.12.0
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

# A stub `claude` reading its behavior from $MOCK_STATE, and logging every
# invocation so tests can assert what the script actually did.
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
            printf '    Version: 0.12.0\n'
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
        # A successful install makes THAT plugin visible to a later list call —
        # this is what lets a repair test observe a real state transition.
        echo "enabled" >"$MOCK_STATE/status-${3%%@*}"
        exit 0
        ;;
    "plugin enable")
        echo "enabled" >"$MOCK_STATE/status-${3%%@*}"
        exit 0
        ;;
    "plugin marketplace")
        if [ "$(command cat "$MOCK_STATE/marketplace_fails" 2>/dev/null || echo 0)" = "1" ]; then
            echo "marketplace add failed: no such directory" >&2
            exit 1
        fi
        exit 0
        ;;
esac
exit 0
STUB
    chmod 755 "$STUB_BIN/claude"
}

# Run the real script under the stubbed environment. Echoes combined output;
# returns the script's exit code.
_run_repair() {
    local rc=0
    # BASH_ENV is cleared because /etc/bash_env rebuilds PATH on non-interactive
    # bash, which would put the real `claude` ahead of the stub.
    env -u BASH_ENV \
        PATH="$STUB_BIN:$PATH" \
        HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" \
        CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        LIBRARIAN_DIR_TEST_OVERRIDE="$FAKE_LIBRARIAN" \
        ENABLED_FEATURES_FILE="/nonexistent-enabled-features" \
        CLAUDE_LIBRARIAN_PLUGINS="dev-core,review-audit,workflow" \
        CLAUDE_SETUP_RETRY_DELAY=0 \
        bash "$REPAIR" "$@" 2>&1 || rc=$?
    return $rc
}

# ============================================================================
# Fail-loud contract
# ============================================================================
# The headline AC: a no-op repair must not be mistakable for a successful one.

test_missing_librarian_dir_fails_loud() {
    setup
    command rm -rf "$FAKE_LIBRARIAN"

    local out rc=0
    out=$(_run_repair repair) || rc=$?

    assert_equals "3" "$rc" "a missing librarian tree exits 3, not 0"
    assert_contains "$out" "not found" "the error names the missing tree"
    assert_contains "$out" "$FAKE_LIBRARIAN" "the error names the path it looked at"
    teardown
}

test_missing_librarian_dir_fails_loud_on_check() {
    setup
    command rm -rf "$FAKE_LIBRARIAN"

    local rc=0
    _run_repair check >/dev/null || rc=$?

    assert_equals "3" "$rc" "check also refuses without a librarian tree"
    teardown
}

# A missing library is a broken install, not a plugin problem — it must not be
# reported as "plugins are fine".
test_missing_plugin_lib_fails_loud() {
    setup
    local out rc=0
    out=$(env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" \
        CLAUDE_PLUGIN_LIB="/nonexistent/claude-plugin-lib.sh" \
        LIBRARIAN_DIR_TEST_OVERRIDE="$FAKE_LIBRARIAN" \
        bash "$REPAIR" check 2>&1) || rc=$?

    assert_equals "3" "$rc" "a missing shared library exits 3"
    assert_contains "$out" "claude-plugin-lib.sh" "the error names the missing library"
    teardown
}

# ============================================================================
# Usage
# ============================================================================

test_no_subcommand_is_usage_error() {
    setup
    local out rc=0
    out=$(_run_repair) || rc=$?

    assert_equals "2" "$rc" "no subcommand exits 2"
    assert_contains "$out" "Usage:" "usage is printed"
    teardown
}

test_unknown_subcommand_is_usage_error() {
    setup
    local out rc=0
    out=$(_run_repair frobnicate) || rc=$?

    assert_equals "2" "$rc" "an unknown subcommand exits 2"
    assert_contains "$out" "frobnicate" "the error names the bad subcommand"
    teardown
}

# --help must work with no librarian tree and no library — it is what an
# operator reaches for when the environment is already broken.
test_help_works_without_environment() {
    setup
    command rm -rf "$FAKE_LIBRARIAN"

    local out rc=0
    out=$(env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        CLAUDE_PLUGIN_LIB="/nonexistent" LIBRARIAN_DIR_TEST_OVERRIDE="/nonexistent" \
        bash "$REPAIR" --help 2>&1) || rc=$?

    assert_equals "0" "$rc" "--help exits 0 even with nothing installed"
    assert_contains "$out" "repair" "help documents the repair subcommand"
    assert_contains "$out" "check" "help documents the check subcommand"
    teardown
}

# ============================================================================
# check — read-only
# ============================================================================

test_check_reports_healthy() {
    setup
    local out rc=0
    out=$(_run_repair check) || rc=$?

    assert_equals "0" "$rc" "a fully registered host exits 0"
    assert_contains "$out" "Marketplace registered" "check reports the marketplace"
    assert_contains "$out" "workflow" "check reports each plugin"
    teardown
}

test_check_detects_deregistered_marketplace() {
    setup
    _write_marketplaces_without_librarian

    local out rc=0
    out=$(_run_repair check) || rc=$?

    assert_equals "1" "$rc" "a dropped marketplace makes check exit 1"
    assert_contains "$out" "NOT registered" "check names the dropped marketplace"
    teardown
}

test_check_detects_uninstalled_plugins() {
    setup
    _set_all_status "absent"

    local out rc=0
    out=$(_run_repair check) || rc=$?

    assert_equals "1" "$rc" "uninstalled plugins make check exit 1"
    assert_contains "$out" "not installed" "check says which plugins are gone"
    teardown
}

test_check_detects_disabled_plugins() {
    setup
    _set_all_status "disabled"

    local out rc=0
    out=$(_run_repair check) || rc=$?

    assert_equals "1" "$rc" "installed-but-disabled makes check exit 1"
    assert_contains "$out" "DISABLED" "check distinguishes disabled from absent"
    teardown
}

# check must write NOTHING. It is safe to run mid-incident and from a status
# dashboard, and that is only true if it never mutates.
test_check_is_read_only() {
    setup
    _write_marketplaces_without_librarian
    _set_all_status "absent"

    _run_repair check >/dev/null || true

    local calls
    calls=$(command cat "$MOCK_STATE/calls" 2>/dev/null || echo "")

    assert_not_contains "$calls" "plugin install" "check never installs"
    assert_not_contains "$calls" "plugin enable" "check never enables"
    assert_not_contains "$calls" "marketplace add" "check never registers"
    teardown
}

# ============================================================================
# repair
# ============================================================================

test_repair_registers_missing_marketplace() {
    setup
    _write_marketplaces_without_librarian
    _set_all_status "absent"

    local rc=0
    _run_repair repair >/dev/null || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_equals "0" "$rc" "repair succeeds on a de-registered host"
    assert_contains "$calls" "marketplace add" "repair re-registers the marketplace"
    teardown
}

# The exact failure from the issue: registry files gone, cache intact.
test_repair_reinstalls_absent_plugins() {
    setup
    _set_all_status "absent"

    local rc=0
    _run_repair repair >/dev/null || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_equals "0" "$rc" "repair succeeds"
    assert_contains "$calls" "plugin install dev-core@librarian" "dev-core reinstalled"
    assert_contains "$calls" "plugin install review-audit@librarian" "review-audit reinstalled"
    assert_contains "$calls" "plugin install workflow@librarian" "workflow reinstalled"
    teardown
}

test_repair_reenables_disabled_plugins() {
    setup
    _set_all_status "disabled"

    local rc=0
    _run_repair repair >/dev/null || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_equals "0" "$rc" "repair succeeds"
    assert_contains "$calls" "plugin enable" "a disabled plugin is re-enabled, not reinstalled"
    teardown
}

# Idempotency, asserted by OUTCOME rather than by re-reading the source: a
# second run against a healthy host must install nothing at all.
test_repair_is_idempotent() {
    setup
    _run_repair repair >/dev/null || true
    : >"$MOCK_STATE/calls"

    local rc=0
    _run_repair repair >/dev/null || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_equals "0" "$rc" "the second run also succeeds"
    assert_not_contains "$calls" "plugin install" "a healthy host is not reinstalled"
    teardown
}

test_repair_honors_librarian_plugins_override() {
    setup
    _set_all_status "absent"

    local rc=0
    env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        LIBRARIAN_DIR_TEST_OVERRIDE="$FAKE_LIBRARIAN" \
        ENABLED_FEATURES_FILE="/nonexistent-enabled-features" \
        CLAUDE_LIBRARIAN_PLUGINS="dev-core" \
        bash "$REPAIR" repair >/dev/null 2>&1 || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_contains "$calls" "plugin install dev-core@librarian" "the named plugin is installed"
    assert_not_contains "$calls" "plugin install workflow@librarian" \
        "a plugin outside the override is left alone"
    teardown
}

# The _trim call sites END-TO-END (#943), not the helper in isolation.
#
# An operator writing a CSV by hand naturally writes "dev-core, review-audit".
# _trim is unit-tested above and _is_in_list is driven with padded entries, but
# librarian_install_plugins and librarian_verify_plugins are the two loops that
# actually consume an operator's list, and every other test here passes values
# with no interior whitespace. A quoting slip at either call site would leave
# every unit test green while installing a mangled or empty plugin name — the
# exact bug class this issue exists to close.
test_padded_plugin_list_installs_correctly() {
    setup
    _set_all_status "absent"

    local rc=0
    env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        LIBRARIAN_DIR_TEST_OVERRIDE="$FAKE_LIBRARIAN" \
        ENABLED_FEATURES_FILE="/nonexistent-enabled-features" \
        CLAUDE_LIBRARIAN_PLUGINS="dev-core, review-audit ,	workflow" \
        bash "$REPAIR" repair >/dev/null 2>&1 || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_contains "$calls" "plugin install dev-core@librarian" \
        "a space-padded first entry installs under its clean name"
    assert_contains "$calls" "plugin install review-audit@librarian" \
        "an entry padded on both sides installs under its clean name"
    assert_contains "$calls" "plugin install workflow@librarian" \
        "a tab-padded entry installs under its clean name"

    # The failure mode is a name that still carries its padding, which would
    # reach `claude plugin install` verbatim and fail against the marketplace.
    assert_not_contains "$calls" "plugin install  " \
        "no install is issued with a leading-space plugin name"
    teardown
}

test_repair_honors_disabled_plugins_kill_switch() {
    setup
    _set_all_status "absent"

    local rc=0
    env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        LIBRARIAN_DIR_TEST_OVERRIDE="$FAKE_LIBRARIAN" \
        ENABLED_FEATURES_FILE="/nonexistent-enabled-features" \
        CLAUDE_LIBRARIAN_PLUGINS="dev-core,review-audit,workflow" \
        CLAUDE_DISABLED_PLUGINS="workflow" \
        bash "$REPAIR" repair >/dev/null 2>&1 || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_contains "$calls" "plugin install dev-core@librarian" "un-denied plugins still install"
    assert_not_contains "$calls" "plugin install workflow@librarian" \
        "the deny-list suppresses install, not just re-enable (#789)"
    teardown
}

# A failed marketplace registration is absorbed (`|| true`) so one bad plugin
# cannot abort a boot — which means the WARNING is the only signal it happened.
# If that line ever stopped being printed, the failure would be fully silent.
test_failed_marketplace_registration_warns() {
    setup
    _write_marketplaces_without_librarian
    _set_all_status "absent"
    echo "1" >"$MOCK_STATE/marketplace_fails"

    local out rc=0
    out=$(_run_repair repair) || rc=$?

    assert_contains "$out" "Failed to register librarian marketplace" \
        "a failed registration is reported, not swallowed"
    assert_contains "$out" "marketplace add failed" \
        "the underlying CLI error is surfaced"
    teardown
}

# ============================================================================
# Component discovery verification (the AC that install-exit-code cannot cover)
# ============================================================================
# `claude plugin install` exiting 0 does not prove the plugin's skills, agents,
# and hooks were discovered. Both fixtures below install "successfully".

test_repair_fails_when_hooks_not_discovered() {
    setup
    _set_all_status "absent"
    # workflow installs fine but reports Hooks (0) — hooks.json unwired.
    _write_details "workflow" 10 3 0

    local out rc=0
    out=$(_run_repair repair) || rc=$?

    assert_equals "1" "$rc" "Hooks (0) fails the repair despite a clean install"
    assert_contains "$out" "Hooks (0)" "the failure names the observed count"
    assert_contains "$out" "expected Hooks (2)" "the failure names the expected count"
    teardown
}

test_repair_fails_when_agents_not_discovered() {
    setup
    _set_all_status "absent"
    # The nested-agents layout: agents present on disk, discovered as zero.
    _write_details "dev-core" 21 0 0

    local out rc=0
    out=$(_run_repair repair) || rc=$?

    assert_equals "1" "$rc" "Agents (0) fails the repair"
    assert_contains "$out" "no agents discovered" "the failure explains the flat-layout requirement"
    teardown
}

test_repair_fails_when_skills_not_discovered() {
    setup
    _set_all_status "absent"
    _write_details "review-audit" 0 10 0

    local out rc=0
    out=$(_run_repair repair) || rc=$?

    assert_equals "1" "$rc" "Skills (0) fails the repair"
    assert_contains "$out" "no skills discovered" "the failure names the empty component"
    teardown
}

# Only workflow ships hooks; dev-core and review-audit legitimately have none
# and must not be failed for it.
test_hookless_plugins_are_not_failed_for_zero_hooks() {
    setup
    local out rc=0
    out=$(_run_repair check) || rc=$?

    assert_equals "0" "$rc" "dev-core and review-audit pass with Hooks (0)"
    assert_contains "$out" "dev-core" "the hookless plugin is still reported"
    teardown
}

# All plugins are checked before reporting — stopping at the first failure would
# hide the other two from an operator who wants one complete report.
test_verification_reports_every_failure() {
    setup
    _set_all_status "absent"
    _write_details "dev-core" 0 6 0
    _write_details "review-audit" 0 10 0

    local out rc=0
    out=$(_run_repair repair) || rc=$?

    assert_equals "1" "$rc" "the repair fails"
    assert_contains "$out" "dev-core" "the first failure is reported"
    assert_contains "$out" "review-audit" "the second failure is reported too"
    teardown
}

# check must apply the same discovery bar as repair. An enabled-but-inert plugin
# is exactly the state the issue describes, and "enabled" alone does not clear it.
test_check_verifies_discovery_not_just_enablement() {
    setup
    _write_details "workflow" 10 3 0

    local out rc=0
    out=$(_run_repair check) || rc=$?

    assert_equals "1" "$rc" "an enabled but inert plugin fails check"
    assert_contains "$out" "Hooks (0)" "check names the discovery failure"
    teardown
}

# ============================================================================
# Parser unit tests
# ============================================================================
# The count parser is pure, so it is driven directly with fixture text.

_load_parser() {
    # shellcheck source=/dev/null
    source "$PLUGIN_LIB"
}

test_parse_component_count_reads_each_label() {
    setup
    _load_parser
    local blob
    blob=$(command cat "$MOCK_STATE/details-workflow")

    assert_equals "10" "$(_librarian_parse_component_count "Skills" "$blob")" "Skills parsed"
    assert_equals "3" "$(_librarian_parse_component_count "Agents" "$blob")" "Agents parsed"
    assert_equals "2" "$(_librarian_parse_component_count "Hooks" "$blob")" "Hooks parsed"
    teardown
}

test_parse_component_count_absent_label_is_empty() {
    setup
    _load_parser
    local blob
    blob=$(command cat "$MOCK_STATE/details-workflow")

    assert_empty "$(_librarian_parse_component_count "Wombats" "$blob")" \
        "an absent label yields empty, not 0 — 'missing' is not 'zero'"
    teardown
}

# "MCP servers (0)" must not satisfy a query for "servers": the label is
# anchored, so a partial match cannot silently pass a different component's count.
test_parse_component_count_is_anchored() {
    setup
    _load_parser
    local blob
    blob=$(command cat "$MOCK_STATE/details-workflow")

    assert_empty "$(_librarian_parse_component_count "servers" "$blob")" \
        "a mid-line substring does not match the anchored label"
    teardown
}

test_expected_hooks_only_for_workflow() {
    setup
    _load_parser

    assert_equals "2" "$(_librarian_expected_hooks workflow)" "workflow requires 2 hooks"
    assert_empty "$(_librarian_expected_hooks dev-core)" "dev-core has no hook requirement"
    assert_empty "$(_librarian_expected_hooks review-audit)" "review-audit has no hook requirement"
    teardown
}

# ============================================================================
# Mutual exclusion (#784 / #777)
# ============================================================================
# A repair is run BY HAND mid-session — precisely the window in which the auth
# watcher may fire claude-setup. Both write ~/.claude/settings.json
# non-atomically, so the loser's writes are clobbered and plugins end up
# installed-but-disabled: the exact state this script repairs.

# Mutual exclusion only holds if BOTH entry points lock the SAME path. Two
# hardcoded literals could drift apart silently and would exclude nothing, so
# the constant is shared and both call sites are pinned to it.
test_both_entrypoints_share_one_lock_path() {
    setup
    local setup_src="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"

    assert_file_contains "$PLUGIN_LIB" 'CLAUDE_SETUP_LOCK="/etc/container/lock/claude-setup.lock"' \
        "the shared library owns the lock path constant"

    # The directory must not be world-writable (#943): the /tmp path this
    # replaced let any local user plant a symlink at the lock path.
    assert_file_not_contains "$PLUGIN_LIB" 'CLAUDE_SETUP_LOCK="/tmp/' \
        "the lock does not live in a world-writable directory"

    local caller
    for caller in "$REPAIR" "$setup_src"; do
        if command grep -qE '^[[:space:]]*_acquire_setup_lock "\$CLAUDE_SETUP_LOCK"' "$caller"; then
            pass_test "${caller##*/} locks via the shared constant"
        else
            fail_test "${caller##*/} does not take the shared setup lock"
        fi
    done

    # An env-derived path would resolve differently across process trees (a
    # backgrounded startup script vs an operator's shell), silently restoring
    # the race the lock exists to prevent.
    if command grep -qE 'CLAUDE_SETUP_LOCK=.*\$\{?TMPDIR' "$PLUGIN_LIB"; then
        fail_test "lock path is env-derived — the entry points may not agree"
    else
        pass_test "lock path does not depend on TMPDIR"
    fi
    teardown
}

# check must NOT lock: it writes nothing, so taking a 600s-blocking lock would
# make a read-only status query hang behind an in-flight repair.
test_check_does_not_take_the_lock() {
    setup
    local lockfile="$TEST_TEMP_DIR/held.lock"
    : >"$lockfile"

    if ! command -v flock >/dev/null 2>&1; then
        skip_test "flock not available on this host"
        teardown
        return 0
    fi

    # Hold the lock, then confirm `check` still completes promptly.
    local rc=0
    flock "$lockfile" -c 'sleep 5' &
    local holder=$!
    sleep 0.3

    local start end
    start=$(date +%s)
    _run_repair check >/dev/null || rc=$?
    end=$(date +%s)

    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true

    if [ $((end - start)) -lt 4 ]; then
        pass_test "check returns without waiting on the setup lock"
    else
        fail_test "check blocked on the lock — a read-only query must not"
    fi
    teardown
}

# The degraded paths must stay DISTINCT. "flock is not installed" and "flock
# works but the lock file could not be opened" have different fixes, and one
# shared message sends the operator after the wrong one.
test_lock_failure_branches_are_distinguishable() {
    setup
    local runner="$TEST_TEMP_DIR/lock-runner.sh"
    # A PATH holding the interpreter and coreutils but NOT flock. Emptying PATH
    # outright would make `bash` itself unresolvable, and the test would "fail"
    # on a missing interpreter rather than on the branch under test.
    local nolock_bin="$TEST_TEMP_DIR/nolock-bin"
    mkdir -p "$nolock_bin"
    local tool
    for tool in bash cat sed grep awk head; do
        local resolved
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$nolock_bin/$tool"
    done

    {
        echo '#!/usr/bin/env bash'
        _extract_lock_function
        echo '_acquire_setup_lock "$1"'
        echo 'echo REACHED'
    } >"$runner"

    # Branch 1: flock genuinely absent (PATH resolves everything but flock).
    local out
    out=$(env -u BASH_ENV PATH="$nolock_bin" bash "$runner" "$TEST_TEMP_DIR/a.lock" 2>&1) || true
    assert_contains "$out" "flock not available" "a missing flock says so"
    assert_contains "$out" "REACHED" "a missing flock warns and continues"

    # Branch 2: flock present, but the lock path cannot be opened.
    out=$(env -u BASH_ENV bash "$runner" "$TEST_TEMP_DIR/no-such-dir/b.lock" 2>&1) || true
    assert_contains "$out" "could not open" "an unopenable path says THAT, not 'flock not available'"
    assert_not_contains "$out" "flock not available" \
        "the two degraded paths are not collapsed into one message"
    assert_contains "$out" "REACHED" "an unopenable path warns and continues"
    teardown
}

# The lock path guard (#943). The root-owned parent directory is the real
# control, but it exists only in a built image — these drive the in-process
# check that backs it up, which is what would fire if the path ever moved back
# somewhere writable.

# Run _acquire_setup_lock against a given path in a fresh bash, with flock
# stubbed to succeed so the test never actually blocks. Echoes the combined
# output; REACHED in it means the function returned rather than exiting.
_run_acquire_lock() {
    local lock_path="$1"
    local runner="$TEST_TEMP_DIR/lock-guard-runner.sh"
    local stub_bin="$TEST_TEMP_DIR/lock-guard-bin"

    mkdir -p "$stub_bin"
    command printf '#!/usr/bin/env bash\nexit 0\n' >"$stub_bin/flock"
    chmod 755 "$stub_bin/flock"

    {
        echo '#!/usr/bin/env bash'
        _extract_lock_function
        echo '_acquire_setup_lock "$1"'
        echo 'echo REACHED'
    } >"$runner"

    env -u BASH_ENV PATH="$stub_bin:$PATH" bash "$runner" "$lock_path" 2>&1 || true
}

# A symlinked lock path is the /tmp attack this move closes: an unprivileged
# user plants a symlink, and the fd-200 open writes wherever it points.
test_symlinked_lock_path_is_refused() {
    setup
    local target="$TEST_TEMP_DIR/attacker-target"
    local link="$TEST_TEMP_DIR/planted.lock"
    ln -s "$target" "$link"

    local out
    out=$(_run_acquire_lock "$link")

    assert_contains "$out" "symlink" "a symlinked lock path says THAT specifically"
    assert_contains "$out" "REACHED" "a symlinked lock path degrades rather than exiting"
    assert_file_not_exists "$target" \
        "the symlink was NOT followed — nothing was created at its target"
    teardown
}

# The message must name the actual cause. Collapsing this into the existing
# "could not open" or "flock not available" text would send an operator after
# the wrong fix — the same property the two pre-existing branches assert.
test_lock_guard_messages_are_distinct() {
    setup
    local link="$TEST_TEMP_DIR/distinct.lock"
    ln -s "$TEST_TEMP_DIR/elsewhere" "$link"

    local out
    out=$(_run_acquire_lock "$link")

    assert_not_contains "$out" "flock not available" \
        "a symlinked path is not reported as a missing flock"
    assert_not_contains "$out" "could not open" \
        "a symlinked path is not reported as an unopenable path"
    teardown
}

# An ordinary, user-owned path in a normal directory must still lock. Without
# this the two refusal tests above would pass on a guard that rejected
# everything.
test_ordinary_lock_path_is_accepted() {
    setup
    local lock="$TEST_TEMP_DIR/ordinary.lock"

    local out
    out=$(_run_acquire_lock "$lock")

    assert_contains "$out" "REACHED" "an ordinary lock path is acquired"
    assert_not_contains "$out" "⚠" "an ordinary lock path warns about nothing"
    assert_file_exists "$lock" "the lock file was created at the requested path"
    teardown
}

# The UID-agnostic property (#943), and the reason there is no ownership check.
#
# The lock file is created at BUILD time, but editors remap the container user's
# UID AFTER build (Zed adopts the host UID; lib/runtime/lib/fix-run-permissions.sh
# exists to reconcile exactly this for /run). A lock a remapped user cannot open
# fails `exec 200>` and degrades to unlocked — silently restoring the race #784
# closed. So a lock file owned by SOMEONE ELSE must still be acquired.
test_lock_owned_by_another_user_is_still_acquired() {
    setup
    local lock

    # A root-owned 0666 file this process does NOT own — the exact shape
    # claude-code-setup.sh installs, and what a UID-remapped runtime sees.
    # /dev/null is that file on every supported distro and needs no privilege
    # to obtain, so this test runs everywhere rather than skipping (a skip
    # would render as a pass and cover nothing).
    lock="/dev/null"

    if [ -O "$lock" ]; then
        fail_test "/dev/null is owned by this process — fixture assumption broken"
        teardown
        return 0
    fi

    local out
    out=$(_run_acquire_lock "$lock")

    assert_contains "$out" "REACHED" "a foreign-owned lock is still acquired"
    assert_not_contains "$out" "owned by another user" \
        "no ownership check — a UID-remapped runtime must not degrade to unlocked"
    assert_not_contains "$out" "could not open" \
        "a 0666 lock file is openable regardless of which UID opens it"
    teardown
}

# The mode the build installs is what makes the above true. 0644 owned by the
# build-time UID would be unopenable by a remapped user; 0666 is openable by
# any of them, and is safe only because the parent directory is root-owned 0755.
test_build_installs_a_uid_agnostic_lock_file() {
    setup
    local setup_sh="$PROJECT_ROOT/lib/features/claude-code-setup.sh"

    assert_file_contains "$setup_sh" 'install -d -m 755 -o root -g root /etc/container/lock' \
        "the lock DIRECTORY is root-owned and not writable by the container user"
    assert_file_contains "$setup_sh" 'install -m 666 -o root -g root /dev/null' \
        "the lock FILE is mode 666 so any runtime UID can open it"
    teardown
}

# A bare host or test harness has no /etc/container/lock. That must degrade the
# same warn-and-continue way, not abort setup.
test_absent_lock_directory_degrades() {
    setup

    local out
    out=$(_run_acquire_lock "$TEST_TEMP_DIR/no-such-dir/absent.lock")

    assert_contains "$out" "could not open" "an absent lock directory says so"
    assert_contains "$out" "REACHED" "an absent lock directory does not abort setup"
    teardown
}

# Extract _acquire_setup_lock from the library (column-0 layout, shfmt-enforced).
_extract_lock_function() {
    command awk '
        $0 == "_acquire_setup_lock() {" { in_fn = 1 }
        in_fn { print }
        in_fn && $0 == "}" { exit }
    ' "$PLUGIN_LIB"
}

# ============================================================================
# Whitespace trimming (#943)
# ============================================================================
# _trim replaced an `echo "$x" | xargs` pipeline at three call sites. The
# aliasing concern is what CLAUDE.md's convention is about, but the sharper bug
# is that `xargs` INTERPRETS its input: it strips quotes and processes
# backslashes, so those values came back altered rather than merely trimmed.

# Source just the library into this shell to drive its pure helpers directly.
# The library is sourced-not-executed by design and sets no shell options.
_source_plugin_lib() {
    # shellcheck disable=SC1090  # path is a test fixture, resolved at runtime
    source "$PLUGIN_LIB"
}

test_trim_strips_surrounding_whitespace() {
    setup
    _source_plugin_lib

    assert_equals "dev-core" "$(_trim "  dev-core")" "leading spaces are stripped"
    assert_equals "dev-core" "$(_trim "dev-core  ")" "trailing spaces are stripped"
    assert_equals "dev-core" "$(_trim "  dev-core  ")" "both ends are stripped"
    assert_equals "dev-core" "$(_trim "$(command printf '\tdev-core\t')")" \
        "tabs are whitespace too"
    assert_equals "dev-core" "$(_trim "dev-core")" "an already-clean value is unchanged"
    teardown
}

test_trim_handles_empty_and_all_whitespace() {
    setup
    _source_plugin_lib

    assert_equals "" "$(_trim "")" "an empty value trims to empty"
    assert_equals "" "$(_trim "   ")" "an all-whitespace value trims to empty"
    teardown
}

# The behavioral difference from `xargs`, and the reason this is not a cosmetic
# swap. `echo 'a"b' | xargs` warns or mangles; `echo 'a\b' | xargs` yields 'ab'.
# _trim must return everything between the outermost non-space characters
# byte-for-byte.
test_trim_does_not_interpret_quotes_or_backslashes() {
    setup
    _source_plugin_lib

    assert_equals 'a"b' "$(_trim '  a"b  ')" "a double quote survives trimming"
    assert_equals "a'b" "$(_trim "  a'b  ")" "a single quote survives trimming"
    assert_equals 'a\b' "$(_trim '  a\b  ')" "a backslash survives trimming"
    assert_equals 'a b' "$(_trim '  a b  ')" "interior whitespace is preserved"
    teardown
}

# The call sites, not just the helper: _is_in_list is what actually consumes
# padded entries, and it is the deny-list's matcher (#789).
test_is_in_list_matches_padded_entries() {
    setup
    _source_plugin_lib

    assert_true "_is_in_list 'workflow' 'dev-core, workflow, review-audit'" \
        "a space-padded entry still matches"
    assert_true "_is_in_list 'workflow' '  workflow  '" \
        "a lone padded entry still matches"
    assert_false "_is_in_list 'work' 'dev-core, workflow'" \
        "matching stays exact — a prefix does not match"
    assert_false "_is_in_list 'workflow' ''" \
        "an empty list matches nothing"
    teardown
}

# ============================================================================
# Pinning contract
# ============================================================================
# The repair must operate on the image-baked cache, never a working tree. This
# one IS a source assertion, deliberately: the property is "no code path reaches
# for a checkout", which is a statement about the whole file rather than about
# any single execution.

# The pin is only as strong as LIBRARIAN_DIR being unreachable from ordinary
# container configuration. If a plain `LIBRARIAN_DIR=...` in a compose
# `environment:` block, a `.env`, or a build arg could redirect it, anything
# controlling the environment could point the trusted local marketplace at an
# arbitrary tree — installing whatever is there instead of the LIBRARIAN_REF
# version the image was built with, with no warning.
test_production_librarian_dir_is_not_env_settable() {
    setup
    local evil="$TEST_TEMP_DIR/evil-checkout"
    mkdir -p "$evil"

    # Set the PRODUCTION variable (not the test seam) and confirm it is ignored:
    # the run must still resolve /opt/librarian, which does not exist here, so
    # it fails loud with exit 3 rather than quietly using $evil.
    local out rc=0
    out=$(env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        ENABLED_FEATURES_FILE="/nonexistent-enabled-features" \
        LIBRARIAN_DIR="$evil" \
        bash "$REPAIR" check 2>&1) || rc=$?

    assert_not_contains "$out" "$evil" \
        "a plain LIBRARIAN_DIR env var cannot redirect the marketplace"
    assert_contains "$out" "/opt/librarian" \
        "the fixed literal is what gets resolved"

    # And the source says so: a bare ${LIBRARIAN_DIR:-...} default would
    # reintroduce the override.
    assert_file_contains "$PLUGIN_LIB" 'LIBRARIAN_DIR="/opt/librarian"' \
        "the library assigns the pinned path as a literal"
    assert_file_not_contains "$PLUGIN_LIB" 'LIBRARIAN_DIR="${LIBRARIAN_DIR:-' \
        "the library does not accept LIBRARIAN_DIR from the environment"
    teardown
}

test_repair_never_reaches_for_a_working_tree() {
    setup
    local code
    code=$(command grep -vE '^[[:space:]]*#' "$REPAIR")

    assert_not_contains "$code" 'marketplace add .' \
        "the repair never registers the current directory"
    assert_not_contains "$code" 'git clone' \
        "the repair never clones — it uses the pinned on-disk cache"
    teardown
}

# The shared-implementation AC. The repair sources the library; it does not
# carry its own copy of the install loop.
test_repair_sources_the_shared_library() {
    setup
    assert_file_contains "$REPAIR" 'source "$CLAUDE_PLUGIN_LIB"' \
        "the repair sources the shared library"
    assert_file_contains "$REPAIR" 'librarian_install_plugins' \
        "the repair calls the shared install path"
    assert_file_not_contains "$REPAIR" 'claude plugin install' \
        "the repair has no install loop of its own — that lives in the library"
    teardown
}

# The build-time config carries CLAUDE_LIBRARIAN_PLUGINS_DEFAULT. Without it the
# override resolves EMPTY and the repair reports "(none)" while fixing nothing —
# a silent no-op of exactly the kind this script exists to prevent.
test_repair_loads_build_time_config() {
    setup
    local conf="$TEST_TEMP_DIR/enabled-features.conf"
    echo 'CLAUDE_LIBRARIAN_PLUGINS_DEFAULT="dev-core"' >"$conf"
    _set_all_status "absent"

    local rc=0
    env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        LIBRARIAN_DIR_TEST_OVERRIDE="$FAKE_LIBRARIAN" \
        ENABLED_FEATURES_FILE="$conf" \
        bash "$REPAIR" repair >/dev/null 2>&1 || rc=$?

    local calls
    calls=$(command cat "$MOCK_STATE/calls")
    assert_contains "$calls" "plugin install dev-core@librarian" \
        "the build-time default drives the plugin list"
    assert_not_contains "$calls" "plugin install workflow@librarian" \
        "a build-time default of one plugin does not install all three"
    teardown
}

# ============================================================================
# Run
# ============================================================================

run_test test_missing_librarian_dir_fails_loud "repair: missing /opt/librarian fails loud (exit 3)"
run_test test_missing_librarian_dir_fails_loud_on_check "check: missing /opt/librarian fails loud (exit 3)"
run_test test_missing_plugin_lib_fails_loud "missing shared library fails loud (exit 3)"
run_test test_no_subcommand_is_usage_error "usage: no subcommand exits 2"
run_test test_unknown_subcommand_is_usage_error "usage: unknown subcommand exits 2"
run_test test_help_works_without_environment "usage: --help works in a broken environment"
run_test test_check_reports_healthy "check: healthy host exits 0"
run_test test_check_detects_deregistered_marketplace "check: detects a de-registered marketplace"
run_test test_check_detects_uninstalled_plugins "check: detects uninstalled plugins"
run_test test_check_detects_disabled_plugins "check: detects installed-but-disabled plugins"
run_test test_check_is_read_only "check: writes nothing"
run_test test_repair_registers_missing_marketplace "repair: re-registers a dropped marketplace"
run_test test_repair_reinstalls_absent_plugins "repair: reinstalls all three plugins"
run_test test_repair_reenables_disabled_plugins "repair: re-enables rather than reinstalls"
run_test test_repair_is_idempotent "repair: idempotent (second run installs nothing)"
run_test test_repair_honors_librarian_plugins_override "repair: honors CLAUDE_LIBRARIAN_PLUGINS"
run_test test_padded_plugin_list_installs_correctly "repair: a space/tab-padded plugin list installs cleanly (#943)"
run_test test_repair_honors_disabled_plugins_kill_switch "repair: honors CLAUDE_DISABLED_PLUGINS (#789)"
run_test test_failed_marketplace_registration_warns "repair: a failed marketplace registration warns loudly"
run_test test_repair_fails_when_hooks_not_discovered "verify: Hooks (0) fails despite a clean install"
run_test test_repair_fails_when_agents_not_discovered "verify: Agents (0) fails despite a clean install"
run_test test_repair_fails_when_skills_not_discovered "verify: Skills (0) fails despite a clean install"
run_test test_hookless_plugins_are_not_failed_for_zero_hooks "verify: hookless plugins are not failed for Hooks (0)"
run_test test_verification_reports_every_failure "verify: reports every failing plugin, not just the first"
run_test test_check_verifies_discovery_not_just_enablement "check: applies the same discovery bar as repair"
run_test test_parse_component_count_reads_each_label "parser: reads Skills/Agents/Hooks counts"
run_test test_parse_component_count_absent_label_is_empty "parser: absent label is empty, not zero"
run_test test_parse_component_count_is_anchored "parser: label match is anchored"
run_test test_expected_hooks_only_for_workflow "parser: only workflow carries a hook requirement"
run_test test_both_entrypoints_share_one_lock_path "lock: both entry points share one lock path"
run_test test_check_does_not_take_the_lock "lock: read-only check never blocks on it"
run_test test_lock_failure_branches_are_distinguishable "lock: degraded branches report distinct causes"
run_test test_symlinked_lock_path_is_refused "lock: a symlinked path is refused, not followed (#943)"
run_test test_lock_guard_messages_are_distinct "lock: the symlink refusal names its own cause"
run_test test_ordinary_lock_path_is_accepted "lock: an ordinary path is still acquired"
run_test test_absent_lock_directory_degrades "lock: an absent lock directory degrades, not aborts"
run_test test_lock_owned_by_another_user_is_still_acquired "lock: a foreign-owned lock is still acquired (UID remap)"
run_test test_build_installs_a_uid_agnostic_lock_file "lock: build installs a UID-agnostic lock file"
run_test test_trim_strips_surrounding_whitespace "trim: strips leading/trailing whitespace (#943)"
run_test test_trim_handles_empty_and_all_whitespace "trim: empty and all-whitespace values"
run_test test_trim_does_not_interpret_quotes_or_backslashes "trim: quotes/backslashes survive (unlike xargs)"
run_test test_is_in_list_matches_padded_entries "trim: _is_in_list matches space-padded entries"
run_test test_production_librarian_dir_is_not_env_settable "pinning: LIBRARIAN_DIR is not env-settable"
run_test test_repair_never_reaches_for_a_working_tree "pinning: never registers a working tree"
run_test test_repair_sources_the_shared_library "sharing: sources the library, carries no install loop"
run_test test_repair_loads_build_time_config "config: build-time default drives the plugin list"

# Generate test report. This is deliberately the LAST command: a suite's exit
# status is its final command's, so anything after it can fake a failure (or
# mask one) independently of the assertions above.
generate_report
