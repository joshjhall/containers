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
#   - LIBRARIAN_DIR pointing at a fixture directory,
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
        LIBRARIAN_DIR="$FAKE_LIBRARIAN" \
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
        LIBRARIAN_DIR="$FAKE_LIBRARIAN" \
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
        CLAUDE_PLUGIN_LIB="/nonexistent" LIBRARIAN_DIR="/nonexistent" \
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
        LIBRARIAN_DIR="$FAKE_LIBRARIAN" \
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

test_repair_honors_disabled_plugins_kill_switch() {
    setup
    _set_all_status "absent"

    local rc=0
    env -u BASH_ENV PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        MOCK_STATE="$MOCK_STATE" CLAUDE_PLUGIN_LIB="$PLUGIN_LIB" \
        LIBRARIAN_DIR="$FAKE_LIBRARIAN" \
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

    assert_file_contains "$PLUGIN_LIB" 'CLAUDE_SETUP_LOCK="/tmp/claude-setup.lock"' \
        "the shared library owns the lock path constant"

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

# Extract _acquire_setup_lock from the library (column-0 layout, shfmt-enforced).
_extract_lock_function() {
    command awk '
        $0 == "_acquire_setup_lock() {" { in_fn = 1 }
        in_fn { print }
        in_fn && $0 == "}" { exit }
    ' "$PLUGIN_LIB"
}

# ============================================================================
# Pinning contract
# ============================================================================
# The repair must operate on the image-baked cache, never a working tree. This
# one IS a source assertion, deliberately: the property is "no code path reaches
# for a checkout", which is a statement about the whole file rather than about
# any single execution.

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
        LIBRARIAN_DIR="$FAKE_LIBRARIAN" \
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
run_test test_repair_honors_disabled_plugins_kill_switch "repair: honors CLAUDE_DISABLED_PLUGINS (#789)"
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
run_test test_repair_never_reaches_for_a_working_tree "pinning: never registers a working tree"
run_test test_repair_sources_the_shared_library "sharing: sources the library, carries no install loop"
run_test test_repair_loads_build_time_config "config: build-time default drives the plugin list"

# Generate test report. This is deliberately the LAST command: a suite's exit
# status is its final command's, so anything after it can fake a failure (or
# mask one) independently of the assertions above.
generate_report
