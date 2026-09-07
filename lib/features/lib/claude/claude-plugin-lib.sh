#!/bin/bash
# claude-plugin-lib.sh - Shared plugin primitives for claude-setup and
#                        claude-plugins-repair.
#
# This library is SOURCED, never executed. It defines functions plus the small
# amount of state they close over; it runs no side effects of its own beyond
# resolving the CLAUDE_DISABLED_PLUGINS deny-list, which every caller needs
# before its first install/enable decision.
#
# WHY IT EXISTS (issue #777)
# --------------------------
# A Claude Code self-update inside a running container silently de-registered
# the librarian marketplace and uninstalled every librarian plugin. claude-setup
# already knew how to repair exactly that — its "Librarian Plugin Installation"
# block is offline, idempotent, and correct — but it only runs at container
# start, so the repair could not fire until the next restart.
#
# claude-plugins-repair is the on-demand trigger. The point of this file is that
# the repair runs THE SAME CODE as the boot path: these functions were MOVED
# here out of claude-setup rather than copied, so the two paths cannot drift.
# Change an install rule once, here.
#
# WHAT LIVES HERE vs WHAT STAYS IN claude-setup
# ---------------------------------------------
# Here: override/deny-list resolution, the `claude plugin list` parsers, the
# enablement-aware status + enable primitives, and the librarian (local,
# offline, no-auth) install and verification path.
#
# Not here: install_plugin() and ensure_marketplace(), which target the
# AUTH-GATED claude-plugins-official marketplace. The repair path is offline by
# definition and never touches them, so moving them would widen this library for
# no caller.
#
# CONTRACT FOR SOURCERS
# ---------------------
#   - Requires bash (arrays, ${!var} indirection, <<< herestrings).
#   - Requires `claude` on PATH for anything that shells out. The pure parsers
#     (_match_plugin_in_list, _plugin_status_in_list, _is_in_list,
#     _file_json_to_csv, _librarian_parse_component_count) are dependency-free
#     and unit-testable in isolation — which is how they are tested.
#   - Requires `jq` for the _FILE-variant overrides only.
#   - Does NOT set -euo pipefail: the sourcing script owns its shell options.
#     Every function returns a status rather than exiting, so a caller running
#     under `set -e` must absorb the failures it wants to survive.

# ============================================================================
# Component Override Helpers
# ============================================================================

# Resolve a component override list from runtime env, build-time default, or fallback.
# Uses __UNSET__ sentinel to distinguish "not specified" from "set to empty".
# Usage: _resolve_override_list "CLAUDE_PLUGINS" "default1,default2"
# Output: the resolved list string (may be empty)
# Returns: 0 if an explicit override is active, 1 if using defaults
_resolve_override_list() {
    local var_name="$1"
    local defaults="$2"
    local default_var="${var_name}_DEFAULT"

    # Runtime env var takes priority
    local runtime_val="${!var_name:-}"
    local default_val="${!default_var:-}"

    # Check if runtime env var is explicitly set (even to empty)
    if [ -n "${!var_name+x}" ]; then
        echo "$runtime_val"
        return 0
    fi

    # Check build-time default (sentinel means "not specified at build time")
    if [ "$default_val" != "__UNSET__" ]; then
        echo "$default_val"
        return 0
    fi

    # Neither set — use built-in defaults
    echo "$defaults"
    return 1
}

# Check if a name is in a comma-separated list (exact match).
# Usage: _is_in_list "name" "a,b,name,c" → returns 0
_is_in_list() {
    local needle="$1"
    local haystack="$2"

    [ -z "$haystack" ] && return 1
    [ -z "$needle" ] && return 1

    local IFS=','
    local item
    for item in $haystack; do
        # Trim whitespace
        item=$(echo "$item" | xargs)
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# Temp file for cross-subshell communication of resolution source.
# Written by _resolve_override_list_or_file, read by callers after $() capture.
_RESOLVED_FROM_FILE=$(mktemp 2>/dev/null || echo "/tmp/.resolved-from-$$")

# Resolve a component list from a JSON file, env var, or built-in defaults.
# Checks ${var_name}_FILE (runtime) then ${var_name}_FILE_DEFAULT (build-time).
# If a valid JSON array file is found, outputs it and writes "file" to _RESOLVED_FROM_FILE.
# Otherwise falls through to _resolve_override_list and writes "env" or "default".
# Usage: result=$(_resolve_override_list_or_file "CLAUDE_PLUGINS" "default1,default2")
#        RESOLVED_FROM=$(cat "$_RESOLVED_FROM_FILE")
# Output: resolved list (JSON array if from file, CSV otherwise)
# Returns: 0 if override active, 1 if using built-in defaults
_resolve_override_list_or_file() {
    local var_name="$1"
    local defaults="$2"
    local file_var="${var_name}_FILE"
    local file_default_var="${var_name}_FILE_DEFAULT"

    # Check runtime file var, then build-time file default
    local file_path="${!file_var:-${!file_default_var:-}}"

    if [ -n "$file_path" ]; then
        if [ ! -f "$file_path" ]; then
            echo "  ⚠ ${file_var}=${file_path} not found, falling through to env var" >&2
        elif ! command jq -e 'type == "array"' "$file_path" >/dev/null 2>&1; then
            echo "  ⚠ ${file_var}=${file_path} is not a valid JSON array, falling through" >&2
        else
            # File valid — warn if env var also set
            if [ -n "${!var_name+x}" ]; then
                echo "  ⚠ ${var_name} ignored — ${file_var} takes precedence" >&2
            fi
            command cat "$file_path"
            echo "file" >"$_RESOLVED_FROM_FILE"
            return 0
        fi
    fi

    # Fall through to existing env var logic
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

# Convert a JSON array to comma-separated values for backward compat.
# Handles both plain strings and objects with a "name" field.
# Usage: _file_json_to_csv '["a","b",{"name":"c"}]'
# Output: a,b,c
_file_json_to_csv() {
    command jq -r 'map(if type == "string" then . else .name // empty end) | join(",")' <<<"$1"
}

# Pattern matching function (testable - takes list output as parameter)
# Output format from 'claude plugin list':
#   ❯ plugin-name@marketplace - description
#   ❯ another-plugin@marketplace - description
#
# NOTE: this is an INSTALLED-or-not predicate — it matches a disabled plugin
# just as happily as an enabled one. Use _plugin_status_in_list when the
# distinction matters (issue #784).
_match_plugin_in_list() {
    local plugin_name="$1"
    local list_output="$2"
    # Match: "❯ plugin-name@" at start of line (after any whitespace)
    # The ❯ character is followed by space, then plugin name, then @
    echo "$list_output" | command grep -qE "^[[:space:]]*❯ ${plugin_name}@" 2>/dev/null
}

# Enablement-aware detection (testable - takes list output as parameter).
# Echoes exactly one of: enabled | disabled | absent
#
# Current 'claude plugin list' emits a multi-line block per plugin:
#   ❯ workflow@librarian
#     Version: 0.10.0
#     Scope: user
#     Status: ✘ disabled
#
# Why this exists (#784): a concurrent-write race can leave a plugin installed
# but DISABLED. _match_plugin_in_list matches it either way, so callers reported
# "already installed" and never repaired the damage — the failure stayed silent
# across container restarts.
#
# A matched block with NO "Status:" line before the next plugin block maps to
# "enabled": older CLI output was single-line (❯ name@marketplace - description)
# and reported no status at all, so treating a missing status as disabled would
# make every old-format path spuriously "repair" itself.
_plugin_status_in_list() {
    local plugin_name="$1"
    local list_output="$2"
    local block
    # Take everything from the plugin's own header line up to (not including)
    # the next header, so a neighbouring block's Status: can never leak in.
    block=$(echo "$list_output" | command awk -v name="$plugin_name" '
        # A header line starts a new block; decide whether it is ours.
        /^[[:space:]]*❯ / {
            in_block = ($0 ~ "^[[:space:]]*❯ " name "@")
            if (in_block) { print; found = 1 }
            next
        }
        in_block { print }
        END { exit (found ? 0 : 1) }
    ') || {
        echo "absent"
        return 0
    }

    if echo "$block" | command grep -qE '^[[:space:]]*Status:.*disabled'; then
        echo "disabled"
    else
        echo "enabled"
    fi
}

# DEPRECATED (#784) — superseded by plugin_status below. Currently has no
# callers; kept only so an out-of-tree caller does not break.
#
# DO NOT use this for install/skip decisions. It is enablement-BLIND: it returns
# true for a plugin that is installed but DISABLED, which is exactly how the
# #784 race went undetected — the second claude-setup run saw "installed",
# logged "already installed", and left every skill from that plugin unavailable.
# Reach for plugin_status (enabled|disabled|absent) instead.
has_plugin() {
    local plugin_name="$1"
    local list_output
    list_output=$(claude plugin list 2>/dev/null) || return 1
    _match_plugin_in_list "$plugin_name" "$list_output"
}

# ----------------------------------------------------------------------------
# Plugin deny-list (#789)
# ----------------------------------------------------------------------------
# CLAUDE_DISABLED_PLUGINS is an emergency kill-switch, not a configuration knob.
# #784 made every plugin named in CLAUDE_PLUGINS / CLAUDE_LIBRARIAN_PLUGINS
# unconditionally re-enabled, which is the right default (a manual disable is
# indistinguishable from race damage) but left no way to keep a misbehaving
# plugin off without editing compose/env and restarting — awkward mid-incident.
#
# The deny-list is checked BEFORE the install/enable decision so it wins over
# every allow-list. That ordering is the whole point.
#
# It suppresses install as well as re-enable: `claude plugin install` enables as
# a side effect, so honoring the deny-list only on the re-enable branch would
# let a fresh ~/.claude volume silently reinstate the plugin.
#
# It never DISABLES anything. An already-enabled denied plugin is reported and
# left alone — claude-setup runs on every boot and should not acquire a
# destructive action. The operator applies it with `claude plugin disable`; the
# deny-list is what makes that survive the next restart.
DISABLED_PLUGINS=""
_resolve_disabled_plugins() {
    local result
    result=$(_resolve_override_list_or_file "CLAUDE_DISABLED_PLUGINS" "") || true
    if [ "$(command cat "$_RESOLVED_FROM_FILE")" = "file" ]; then
        DISABLED_PLUGINS=$(_file_json_to_csv "$result")
    else
        DISABLED_PLUGINS="$result"
    fi
}
_resolve_disabled_plugins

_plugin_is_denied() {
    _is_in_list "$1" "$DISABLED_PLUGINS"
}

# Report a denied plugin's current state and why nothing will happen to it.
# Always logs — a plugin missing from startup output with no explanation is the
# exact silent failure #784 was about.
_log_denied_plugin() {
    local plugin_name="$1"
    case "$(plugin_status "$plugin_name")" in
        enabled)
            echo "    ⚠ $plugin_name listed in CLAUDE_DISABLED_PLUGINS but currently enabled"
            echo "      run 'claude plugin disable ${plugin_name}' to apply it"
            ;;
        disabled)
            echo "    ⊘ $plugin_name (disabled via CLAUDE_DISABLED_PLUGINS — leaving disabled)"
            ;;
        *)
            echo "    ⊘ $plugin_name (disabled via CLAUDE_DISABLED_PLUGINS — not installing)"
            ;;
    esac
}

# plugin_status — enablement-aware wrapper over a live `claude plugin list`.
# Echoes enabled | disabled | absent. A failed list call is reported as
# "absent" so callers fall through to their install path (which has its own
# retry + error reporting) rather than silently skipping.
plugin_status() {
    local plugin_name="$1"
    local list_output
    list_output=$(claude plugin list 2>/dev/null) || {
        echo "absent"
        return 0
    }
    _plugin_status_in_list "$plugin_name" "$list_output"
}

# enable_plugin — repair an installed-but-disabled plugin (#784 AC4).
#
# Policy: any plugin named in CLAUDE_PLUGINS / CLAUDE_LIBRARIAN_PLUGINS is
# ALWAYS re-enabled. The supported way to opt out of a plugin is to remove it
# from those lists, not `claude plugin disable` — a manual disable of a
# still-listed plugin is indistinguishable from race damage, and leaving it
# broken is the silent failure this issue is about.
#
# Never aborts the run: a failed enable warns and returns non-zero for the
# caller to absorb (this script runs under `set -e`).
#
# Retries on the same transient marker install_plugin does (#788). enable is
# reached in exactly the startup window install's backoff was built for — the
# auth-watcher firing right as credentials appear, or the librarian marketplace
# still registering — and a one-shot failure there would leave the plugin
# disabled for the whole boot, undoing the very repair #784 added.
enable_plugin() {
    local plugin_name="$1"
    local full_name="$2"
    local max_retries=4
    local retry_delay="${CLAUDE_SETUP_RETRY_DELAY:-2}"
    local attempt=1
    local output

    echo "    ↻ $plugin_name (installed but disabled — re-enabling)"

    while [ $attempt -le $max_retries ]; do
        if output=$(claude plugin enable "$full_name" 2>&1); then
            echo "    ✓ $plugin_name re-enabled"
            return 0
        fi

        # Only "not found in marketplace" is transient — anything else is a real
        # failure and retrying it just delays the warning.
        if echo "$output" | command grep -q "not found in marketplace"; then
            if [ $attempt -lt $max_retries ]; then
                echo "    ⏳ Marketplace not ready, retrying in ${retry_delay}s... (attempt $attempt/$max_retries)"
                sleep "$retry_delay"
                retry_delay=$((retry_delay * 2)) # Exponential backoff: 2, 4, 8, 16
                attempt=$((attempt + 1))
                continue
            fi
        fi

        break
    done

    echo "    ⚠ Failed to re-enable $plugin_name"
    echo "$output" | command sed 's/^/      /' | command head -5
    return 1
}

# ============================================================================
# Librarian Plugin Installation (no auth required, offline)
# ============================================================================
# The general-purpose skills/agents ship as the librarian plugins. The build
# clones the marketplace to /opt/librarian at a pinned LIBRARIAN_REF
# (claude-code-setup.sh); here we register it as a LOCAL (on-disk) marketplace
# and install the plugins OFFLINE — a directory-sourced marketplace needs no
# network and no authentication, so this runs unconditionally on every boot and
# self-heals a fresh ~/.claude home volume (replaces the #574 stamp re-sync).
#
# LIBRARIAN_DIR is overridable ONLY so the unit suite can point it at a fixture.
# Production callers leave it at /opt/librarian: that tree is the image-baked,
# LIBRARIAN_REF-pinned cache. Pointing it at a librarian working-tree checkout
# would register the UN-pinned tree and silently defeat the pin (#777).
LIBRARIAN_DIR="${LIBRARIAN_DIR:-/opt/librarian}"
LIBRARIAN_MARKETPLACE="librarian"
DEFAULT_LIBRARIAN_PLUGINS="dev-core,review-audit,workflow"

# librarian_resolve_plugins — echo the CSV plugin list this host should have.
# Honors CLAUDE_LIBRARIAN_PLUGINS (and its _FILE variant) exactly as the boot
# path does, because it IS the boot path. May legitimately echo empty, which
# means the operator set the variable to empty and wants no librarian plugins.
librarian_resolve_plugins() {
    local result
    result=$(_resolve_override_list_or_file "CLAUDE_LIBRARIAN_PLUGINS" "$DEFAULT_LIBRARIAN_PLUGINS") || true
    if [ "$(command cat "$_RESOLVED_FROM_FILE")" = "file" ]; then
        _file_json_to_csv "$result"
    else
        command printf '%s\n' "$result"
    fi
}

# librarian_marketplace_registered — read-only predicate over the registry file.
# This is the file a Claude Code self-update was observed to drop the librarian
# entry from while leaving the two GitHub-sourced marketplaces intact (#777).
librarian_marketplace_registered() {
    local known_file="$HOME/.claude/plugins/known_marketplaces.json"
    [ -f "$known_file" ] || return 1
    command grep -q "\"$LIBRARIAN_MARKETPLACE\"" "$known_file" 2>/dev/null
}

# librarian_register_marketplace — ensure the local marketplace is known.
# Returns 0 when registered (already or newly), 1 on a failed registration.
librarian_register_marketplace() {
    local output
    if librarian_marketplace_registered; then
        echo "  ✓ Marketplace registered ($LIBRARIAN_MARKETPLACE)"
        return 0
    elif output=$(claude plugin marketplace add "$LIBRARIAN_DIR" 2>&1); then
        echo "  ✓ Marketplace registered ($LIBRARIAN_MARKETPLACE)"
        return 0
    fi
    echo "  ⚠ Failed to register librarian marketplace: $output"
    return 1
}

# librarian_install_plugins — register the marketplace, then install or re-enable
# each resolved plugin. This body used to sit inline in claude-setup; both the
# boot path and `claude-plugins-repair repair` now call it.
#
# Absorbs per-plugin failures and returns 0 whenever $LIBRARIAN_DIR was present:
# claude-setup runs it on every boot under `set -e`, and one unavailable plugin
# must not abort the whole setup. The repair path does not lean on this return
# value either — it calls librarian_verify_plugins afterwards, because an
# install that exits 0 does not prove the components were discovered (#777).
#
# Returns 1 ONLY when $LIBRARIAN_DIR is absent. That is a real misconfiguration
# rather than a transient failure, and the repair entry point turns it into a
# loud non-zero exit instead of a silent no-op.
librarian_install_plugins() {
    local plugins plugin output plugin_state
    local -a plugin_list

    if [ ! -d "$LIBRARIAN_DIR" ]; then
        return 1
    fi

    librarian_register_marketplace || true

    plugins=$(librarian_resolve_plugins)
    if [ -z "$plugins" ]; then
        echo "    (none — CLAUDE_LIBRARIAN_PLUGINS set to empty)"
        return 0
    fi

    IFS=',' read -ra plugin_list <<<"$plugins"
    for plugin in "${plugin_list[@]}"; do
        plugin=$(echo "$plugin" | xargs)
        [ -z "$plugin" ] && continue
        # Deny-list (#789). Checked here too because this loop has its own
        # inline install path and never calls install_plugin — without it
        # the kill-switch would be inert for the librarian plugins, which
        # are the ones it matters most for.
        if _plugin_is_denied "$plugin"; then
            _log_denied_plugin "$plugin"
            continue
        fi
        # Enablement-aware (#784): the librarian plugins install before the
        # auth-gated official ones, so they sit squarely in the window where
        # a racing run's settings.json write clobbers enabledPlugins. A
        # plain "is it installed" check reported success while leaving every
        # /workflow:* and /review-audit:* skill unavailable.
        plugin_state=$(plugin_status "$plugin")
        if [ "$plugin_state" = "enabled" ]; then
            echo "    ✓ $plugin (already installed)"
        elif [ "$plugin_state" = "disabled" ]; then
            enable_plugin "$plugin" "${plugin}@${LIBRARIAN_MARKETPLACE}" || true
        elif output=$(claude plugin install "${plugin}@${LIBRARIAN_MARKETPLACE}" 2>&1); then
            echo "    ✓ $plugin installed"
        else
            echo "    ⚠ Failed to install $plugin"
            echo "$output" | command sed 's/^/      /' | command head -5
        fi
    done
    return 0
}

# ============================================================================
# Component discovery verification (#777)
# ============================================================================
# A zero exit from `claude plugin install` does NOT prove the plugin's skills,
# agents, and hooks were discovered. Two observed ways to install "successfully"
# and get nothing usable:
#
#   - `workflow` reports Hooks (0) when hooks/hooks.json is not wired.
#   - agents report 0 under a nested agents/<name>/<name>.md layout; Claude Code
#     only discovers plugin agents as FLAT agents/<name>.md files.
#
# Both are silent: the plugin is listed, enabled, and inert. So verification
# reads the component inventory rather than trusting the install exit code.
#
# `claude plugin details <plugin>@<marketplace>` prints:
#
#   Component inventory
#     Skills (10)  file-issue, golem, next-issue, ...
#     Agents (3)  rebase-agent, ci-fixer, issue-filer
#     Hooks (2)  Notification, PreToolUse  (harness-only — no model context cost)
#     MCP servers (0)

# _librarian_parse_component_count — echo the N from "Label (N)" in a details
# blob, or empty when the label is absent.
#
# Pure (takes the blob as a parameter) so the unit suite drives it with fixture
# text and no `claude` on PATH.
#
# The label is anchored at line start after leading whitespace so that
# "MCP servers (0)" can never satisfy a query for "Servers", and the count is
# taken from the FIRST match only — the inventory lists each label once, and a
# plugin name appearing later in a skills list must not be re-read as a count.
_librarian_parse_component_count() {
    local label="$1"
    local details="$2"
    echo "$details" |
        command sed -n "s/^[[:space:]]*${label} (\([0-9][0-9]*\)).*/\1/p" |
        command head -1
}

# _librarian_expected_hooks — echo the hook count a plugin must report, or empty
# when the plugin has no hook requirement.
#
# Only `workflow` ships hooks (Notification + PreToolUse), and it is exactly the
# plugin whose Hooks (0) failure was observed. Keeping this as a lookup rather
# than a blanket "every plugin needs hooks" rule avoids failing dev-core and
# review-audit, which legitimately ship none.
_librarian_expected_hooks() {
    case "$1" in
        workflow) echo 2 ;;
        *) echo "" ;;
    esac
}

# librarian_verify_plugin — assert one plugin's components were discovered.
#
# Checks, in order: the details call succeeds; Skills is present and non-zero;
# Agents is present and non-zero; and, for a plugin with a hook requirement, the
# Hooks count matches exactly.
#
# Emits one line per failure naming what was expected, so a broken plugin is
# actionable rather than merely "not ok". Returns 0 when every check passes.
librarian_verify_plugin() {
    local plugin="$1"
    local details skills agents hooks expected_hooks
    local failures=0

    if ! details=$(claude plugin details "${plugin}@${LIBRARIAN_MARKETPLACE}" 2>&1); then
        echo "    ✗ $plugin — could not read plugin details"
        echo "$details" | command sed 's/^/      /' | command head -5
        return 1
    fi

    skills=$(_librarian_parse_component_count "Skills" "$details")
    agents=$(_librarian_parse_component_count "Agents" "$details")
    hooks=$(_librarian_parse_component_count "Hooks" "$details")
    expected_hooks=$(_librarian_expected_hooks "$plugin")

    if [ -z "$skills" ] || [ "$skills" -eq 0 ]; then
        echo "    ✗ $plugin — no skills discovered (expected a non-zero count)"
        failures=$((failures + 1))
    fi

    if [ -z "$agents" ] || [ "$agents" -eq 0 ]; then
        echo "    ✗ $plugin — no agents discovered (agents must be flat agents/<name>.md)"
        failures=$((failures + 1))
    fi

    if [ -n "$expected_hooks" ] && [ "${hooks:-0}" != "$expected_hooks" ]; then
        echo "    ✗ $plugin — Hooks (${hooks:-0}), expected Hooks ($expected_hooks); hooks/hooks.json is likely unwired"
        failures=$((failures + 1))
    fi

    if [ "$failures" -gt 0 ]; then
        return 1
    fi

    echo "    ✓ $plugin — Skills ($skills), Agents ($agents)${expected_hooks:+, Hooks ($hooks)}"
    return 0
}

# librarian_verify_plugins — verify every resolved plugin. Returns non-zero if
# any plugin fails, after checking them ALL: a repair that stops at the first
# failure hides the other two, and the operator wants one complete report.
librarian_verify_plugins() {
    local plugins plugin
    local -a plugin_list
    local failures=0

    plugins=$(librarian_resolve_plugins)
    [ -z "$plugins" ] && return 0

    IFS=',' read -ra plugin_list <<<"$plugins"
    for plugin in "${plugin_list[@]}"; do
        plugin=$(echo "$plugin" | xargs)
        [ -z "$plugin" ] && continue
        # A denied plugin is absent on purpose — verifying it would report a
        # failure for the operator's own kill-switch.
        _plugin_is_denied "$plugin" && continue
        librarian_verify_plugin "$plugin" || failures=$((failures + 1))
    done

    [ "$failures" -eq 0 ]
}
