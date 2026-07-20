#!/usr/bin/env bash
# Unit tests for bin/seed-host-events.sh (#738)
# Exercises the host-side INCLUDE_HOST_EVENTS installer against synthetic
# ~/.claude dirs in TEST_TEMP_DIR (no Docker, no real host config touched). Covers
# every subcommand and branch: install (fresh + preserve unrelated hooks),
# idempotent re-install, remove (un-wire only ours, prune emptied events, delete
# the hook copy), check (installed / not-installed exit codes), jq-absent skip,
# malformed settings (skip without corruption), atomic write (no temp leftover),
# and the bad/missing-subcommand usage errors.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

SKIP_DOCKER_CHECK=true init_test_framework

test_suite "Bin Seed Host Events Tests"

# Resolve the script under test relative to this test file so the suite runs from
# any cwd.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_REAL="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$PROJECT_ROOT_REAL/bin/seed-host-events.sh"
HOOK_SRC="$PROJECT_ROOT_REAL/lib/features/templates/claude/hooks/claude-host-event.sh"
CLAUDE_SETUP="$PROJECT_ROOT_REAL/lib/features/lib/claude/claude-setup"

# Run the script capturing BOTH stdout/stderr (into HE_OUT) and the real exit code
# (into HE_RC). The exit code must be captured directly from the call —
# `out="$(cmd)"; assert_exit_code_success "msg"` does NOT work: the framework's
# assert_exit_code_success treats a lone message as the command, runs an empty
# command array (always 0), and the assertion becomes vacuous.
run_he() {
    HE_RC=0
    HE_OUT="$("$SCRIPT" "$@" 2>&1)" || HE_RC=$?
}

# A fresh, isolated CLAUDE_DIR for one test (empty — install creates what it needs).
fresh_dir() {
    local d="$TEST_TEMP_DIR/claude-$1"
    command rm -rf "$d"
    command mkdir -p "$d"
    command echo "$d"
}

# Count how many hook-command entries across ALL events reference our copied hook.
count_our_cmds() {
    command jq -r --arg d "$1" '
        [ .hooks // {} | .[][]? | .hooks[]? | .command
          | select(startswith($d + "/hooks/claude-host-event.sh")) ] | length
    ' "$1/settings.json"
}

test_script_exists_and_executable() {
    assert_file_exists "$SCRIPT" "seed-host-events.sh exists"
    assert_executable "$SCRIPT" "seed-host-events.sh is executable"
}

test_hook_source_present() {
    # The installer copies this staged forwarder; if it moves the installer's
    # install path silently no-ops, so guard the assumption.
    assert_file_exists "$HOOK_SRC" "staged claude-host-event.sh forwarder exists"
}

test_install_fresh() {
    local d
    d="$(fresh_dir install-fresh)"

    run_he install "$d"
    assert_equals "0" "$HE_RC" "install exits 0"
    assert_contains "$HE_OUT" "wired to 8 events" "Reports 8 events wired"

    # Hook copied and executable.
    assert_file_exists "$d/hooks/claude-host-event.sh" "Forwarder copied into hooks/"
    assert_executable "$d/hooks/claude-host-event.sh" "Copied forwarder is executable"

    # All 8 mapped events present in settings.json.
    local events
    events="$(command jq -r '.hooks | keys | length' "$d/settings.json")"
    assert_equals "8" "$events" "settings.json has all 8 mapped events"

    # SessionStart carries the Idle state arg (spot-check the command shape).
    local cmd
    cmd="$(command jq -r '.hooks.SessionStart[0].hooks[0].command' "$d/settings.json")"
    assert_contains "$cmd" "claude-host-event.sh Idle" "SessionStart wired with Idle state"
}

test_install_creates_settings_when_absent() {
    local d
    d="$(fresh_dir install-nosettings)"
    # No settings.json at all -> install must create it (bootstrapped to {}).
    assert_file_not_exists "$d/settings.json" "Precondition: no settings.json"

    run_he install "$d"
    assert_equals "0" "$HE_RC" "install exits 0 when settings.json absent"
    assert_file_exists "$d/settings.json" "install creates settings.json"
}

test_install_preserves_existing_hooks() {
    local d
    d="$(fresh_dir install-preserve)"
    command mkdir -p "$d"
    # Pre-seed a user's own hook on a mapped event AND an unrelated event.
    command cat >"$d/settings.json" <<'EOF'
{
  "theme": "dark",
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "my-own.sh" }] }],
    "CustomEvent":  [{ "hooks": [{ "type": "command", "command": "keep-me.sh" }] }]
  }
}
EOF

    run_he install "$d"
    assert_equals "0" "$HE_RC" "install exits 0 over existing hooks"

    # User's SessionStart hook survives alongside ours.
    local mine
    mine="$(command jq -r '[.hooks.SessionStart[].hooks[] | select(.command == "my-own.sh")] | length' "$d/settings.json")"
    assert_equals "1" "$mine" "User's own SessionStart hook is preserved"
    # Unrelated event untouched.
    local custom
    custom="$(command jq -r '.hooks.CustomEvent[0].hooks[0].command' "$d/settings.json")"
    assert_equals "keep-me.sh" "$custom" "Unrelated event hook is preserved"
    # Unrelated top-level key untouched.
    local theme
    theme="$(command jq -r '.theme' "$d/settings.json")"
    assert_equals "dark" "$theme" "Unrelated top-level settings preserved"
}

test_install_is_idempotent() {
    local d
    d="$(fresh_dir install-idem)"

    run_he install "$d"
    run_he install "$d"
    assert_equals "0" "$HE_RC" "second install exits 0"

    # Exactly 8 of OUR commands total — no duplication on re-install.
    local ours
    ours="$(count_our_cmds "$d")"
    assert_equals "8" "$ours" "Re-install does not duplicate our hooks (8 total)"
}

test_check_reports_installed() {
    local d
    d="$(fresh_dir check-installed)"
    run_he install "$d"

    run_he check "$d"
    assert_equals "0" "$HE_RC" "check exits 0 when fully installed"
    assert_contains "$HE_OUT" "events wired: 8 / 8" "check reports 8/8 wired"
    assert_contains "$HE_OUT" "fully installed" "check reports fully installed"
}

test_check_reports_not_installed() {
    local d
    d="$(fresh_dir check-absent)"
    command mkdir -p "$d"
    command echo '{}' >"$d/settings.json"

    run_he check "$d"
    assert_equals "1" "$HE_RC" "check exits 1 when not installed"
    assert_contains "$HE_OUT" "not fully installed" "check reports not installed"
}

test_remove_unwires_only_ours() {
    local d
    d="$(fresh_dir remove)"
    command mkdir -p "$d"
    # Install, then add a user hook on a mapped event to prove remove keeps it.
    run_he install "$d"
    command jq '.hooks.SessionStart += [{"hooks":[{"type":"command","command":"my-own.sh"}]}]' \
        "$d/settings.json" >"$d/s2" && command mv "$d/s2" "$d/settings.json"

    run_he remove "$d"
    assert_equals "0" "$HE_RC" "remove exits 0"

    # None of our commands remain...
    local ours
    ours="$(count_our_cmds "$d")"
    assert_equals "0" "$ours" "remove strips all of our hooks"
    # ...but the user's own hook stays.
    local mine
    mine="$(command jq -r '[.hooks.SessionStart[]?.hooks[]? | select(.command == "my-own.sh")] | length' "$d/settings.json")"
    assert_equals "1" "$mine" "remove preserves the user's own hook"
    # The copied hook file is deleted.
    assert_file_not_exists "$d/hooks/claude-host-event.sh" "remove deletes the copied forwarder"
}

test_remove_prunes_emptied_events() {
    local d
    d="$(fresh_dir remove-prune)"
    # Install with no other hooks, then remove: events that held ONLY our hook
    # should be pruned, leaving a clean settings.json (no empty .hooks arrays).
    run_he install "$d"
    run_he remove "$d"
    assert_equals "0" "$HE_RC" "remove exits 0"

    local leftover
    leftover="$(command jq -r '(.hooks // {}) | keys | length' "$d/settings.json")"
    assert_equals "0" "$leftover" "Events holding only our hook are pruned on remove"
}

test_check_after_remove() {
    local d
    d="$(fresh_dir check-after-remove)"
    run_he install "$d"
    run_he remove "$d"

    run_he check "$d"
    assert_equals "1" "$HE_RC" "check exits 1 after remove"
}

test_atomic_write_leaves_no_temp_file() {
    local d
    d="$(fresh_dir atomic)"
    run_he install "$d"

    # The adjacent-temp + atomic-mv pattern must not leave a "settings.json.XXXXXX".
    local leftovers
    leftovers="$(command find "$d" -maxdepth 1 -name 'settings.json.*' | command wc -l | command tr -d ' ')"
    assert_equals "0" "$leftovers" "No temp file left after an atomic write"
}

test_malformed_settings_not_corrupted() {
    local d
    d="$(fresh_dir malformed)"
    command mkdir -p "$d"
    command printf '{ this is not json' >"$d/settings.json"
    local before
    before="$(command cat "$d/settings.json")"

    run_he install "$d"
    # jq merge fails on malformed input -> install reports failure and exits 3.
    assert_equals "3" "$HE_RC" "install on malformed settings exits 3"
    local after
    after="$(command cat "$d/settings.json")"
    assert_equals "$before" "$after" "Malformed settings left byte-for-byte intact"
}

test_skips_when_jq_absent() {
    local d
    d="$(fresh_dir jq-absent)"
    command mkdir -p "$d"
    command echo '{}' >"$d/settings.json"
    local emptybin="$TEST_TEMP_DIR/emptybin"
    command mkdir -p "$emptybin"

    # Run with a PATH containing no jq so `command -v jq` fails. `env -i` starts
    # from a clean environment (a plain PATH=... prefix is undone by the inherited
    # BASH_ENV re-exporting the full PATH). Invoke the interpreter directly since
    # the minimal PATH breaks the `#!/usr/bin/env bash` shebang; the script's own
    # commands are full-path or builtins, so only jq detection is affected.
    local rc=0 out
    out="$(env -i PATH="$emptybin" HOME="$HOME" "$BASH" "$SCRIPT" install "$d" 2>&1)" || rc=$?
    assert_equals "3" "$rc" "jq-absent install exits 3"
    assert_contains "$out" "jq not available" "Reports the jq skip"
}

test_install_preserves_settings_mode() {
    # mktemp creates 0600 and mv carries the source mode over, so a bare mv would
    # silently tighten a 0644 settings.json to 0600. commit_over must restore the
    # destination's prior mode.
    local d
    d="$(fresh_dir mode)"
    command mkdir -p "$d"
    command echo '{}' >"$d/settings.json"
    command chmod 644 "$d/settings.json"

    run_he install "$d"
    assert_equals "0" "$HE_RC" "install exits 0"
    local mode
    mode="$(command stat -c '%a' "$d/settings.json")"
    assert_equals "644" "$mode" "install preserves settings.json 0644 mode (not tightened to 0600)"

    # And remove must likewise preserve it.
    run_he remove "$d"
    mode="$(command stat -c '%a' "$d/settings.json")"
    assert_equals "644" "$mode" "remove preserves settings.json 0644 mode"
}

test_install_missing_forwarder_source_errors() {
    # do_install exits 3 when the staged forwarder ($HOOK_SRC) is missing. Drive
    # that branch by copying the script to a relocated dir whose ../lib/... path
    # has no forwarder, so HOOK_SRC resolves to a non-existent file.
    local relocate="$TEST_TEMP_DIR/relocate/bin"
    command mkdir -p "$relocate"
    command cp "$SCRIPT" "$relocate/seed-host-events.sh"
    local d
    d="$(fresh_dir missing-src)"

    local rc=0 out
    out="$("$relocate/seed-host-events.sh" install "$d" 2>&1)" || rc=$?
    assert_equals "3" "$rc" "install exits 3 when staged forwarder source is missing"
    assert_contains "$out" "staged forwarder not found" "Reports the missing forwarder source"
    assert_file_not_exists "$d/settings.json" "No settings.json written when source is missing"
}

test_remove_malformed_settings_not_corrupted() {
    # do_remove has its own jq-failure branch (analogous to install's). A malformed
    # settings.json must be left byte-for-byte intact and exit 3.
    local d
    d="$(fresh_dir remove-malformed)"
    command mkdir -p "$d"
    command printf '{ not json' >"$d/settings.json"
    local before
    before="$(command cat "$d/settings.json")"

    run_he remove "$d"
    assert_equals "3" "$HE_RC" "remove on malformed settings exits 3"
    local after
    after="$(command cat "$d/settings.json")"
    assert_equals "$before" "$after" "remove leaves malformed settings byte-for-byte intact"
}

# jq-absent guard is shared by all three subcommands (require_jq). Parametrized
# helper so remove/check are covered too, not just install.
assert_jq_absent_exits_3() {
    local sub="$1"
    local d
    d="$(fresh_dir "jq-absent-$sub")"
    command mkdir -p "$d"
    command echo '{}' >"$d/settings.json"
    local emptybin="$TEST_TEMP_DIR/emptybin"
    command mkdir -p "$emptybin"

    local rc=0 out
    out="$(env -i PATH="$emptybin" HOME="$HOME" "$BASH" "$SCRIPT" "$sub" "$d" 2>&1)" || rc=$?
    assert_equals "3" "$rc" "jq-absent $sub exits 3"
    assert_contains "$out" "jq not available" "Reports the jq skip for $sub"
}

test_remove_skips_when_jq_absent() {
    assert_jq_absent_exits_3 remove
}

test_check_skips_when_jq_absent() {
    assert_jq_absent_exits_3 check
}

test_check_malformed_settings_reports_not_installed() {
    # do_check's jq has a `|| command echo 0` fallback for unparsable settings.json.
    # A malformed file must degrade to "0 / 8" and exit 1, never crash.
    local d
    d="$(fresh_dir check-malformed)"
    command mkdir -p "$d"
    command printf '{ not json' >"$d/settings.json"

    run_he check "$d"
    assert_equals "1" "$HE_RC" "check on malformed settings exits 1"
    assert_contains "$HE_OUT" "0 / 8" "check reports 0/8 on malformed settings"
}

test_host_event_map_matches_claude_setup() {
    # The HOST_EVENT_MAP is duplicated byte-identically from claude-setup (AC2).
    # Guard the documented drift risk: extract both maps as canonical JSON and
    # compare. If claude-setup moves, skip with a note rather than hard-fail.
    if [ ! -f "$CLAUDE_SETUP" ]; then
        assert_true "true" "claude-setup not found — drift check skipped"
        return 0
    fi
    # The installer's map: source nothing; extract the HOST_EVENT_MAP literal by
    # asking the script's own environment is overkill — instead compare the two
    # jq-canonicalized event->state objects pulled from each file's literal.
    local from_installer from_setup
    from_installer="$(command sed -n "/^HOST_EVENT_MAP='{/,/^}'/p" "$SCRIPT" |
        command sed "s/^HOST_EVENT_MAP='//; s/'$//" | command jq -S -c .)"
    from_setup="$(command sed -n "/HOST_EVENT_MAP='{/,/}'/p" "$CLAUDE_SETUP" |
        command sed "s/.*HOST_EVENT_MAP='//; s/'$//" | command jq -S -c .)"
    assert_equals "$from_setup" "$from_installer" \
        "HOST_EVENT_MAP is byte-identical (canonical) to claude-setup's"
}

test_missing_subcommand_errors() {
    local rc=0
    "$SCRIPT" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "Missing subcommand exits 2"
}

test_unknown_subcommand_errors() {
    local rc=0 out
    out="$("$SCRIPT" frobnicate 2>&1)" || rc=$?
    assert_equals "2" "$rc" "Unknown subcommand exits 2"
    assert_contains "$out" "unknown subcommand" "Reports the unknown subcommand"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_hook_source_present "Staged forwarder hook source is present"
run_test test_install_fresh "install wires all 8 events on a fresh dir"
run_test test_install_creates_settings_when_absent "install creates settings.json when absent"
run_test test_install_preserves_existing_hooks "install preserves existing + unrelated hooks"
run_test test_install_is_idempotent "install is idempotent (no duplicate hooks)"
run_test test_check_reports_installed "check reports installed (exit 0)"
run_test test_check_reports_not_installed "check reports not installed (exit 1)"
run_test test_remove_unwires_only_ours "remove un-wires only our hooks"
run_test test_remove_prunes_emptied_events "remove prunes events left empty"
run_test test_check_after_remove "check exits 1 after remove"
run_test test_atomic_write_leaves_no_temp_file "Atomic write leaves no temp file"
run_test test_install_preserves_settings_mode "install/remove preserve settings.json mode"
run_test test_malformed_settings_not_corrupted "Malformed settings not corrupted (install)"
run_test test_remove_malformed_settings_not_corrupted "Malformed settings not corrupted (remove)"
run_test test_check_malformed_settings_reports_not_installed "check on malformed settings degrades to 0/8"
run_test test_install_missing_forwarder_source_errors "install exits 3 when forwarder source missing"
run_test test_skips_when_jq_absent "install skips cleanly when jq is absent"
run_test test_remove_skips_when_jq_absent "remove skips cleanly when jq is absent"
run_test test_check_skips_when_jq_absent "check skips cleanly when jq is absent"
run_test test_host_event_map_matches_claude_setup "HOST_EVENT_MAP matches claude-setup (drift guard)"
run_test test_missing_subcommand_errors "Missing subcommand exits 2"
run_test test_unknown_subcommand_errors "Unknown subcommand exits 2"

generate_report
