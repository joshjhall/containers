#!/usr/bin/env bash
# Unit tests for the generated /etc/cron.d/workspace-fs-health entry (Dockerfile)
#
# Issue #800 was a build-time binding in a file nothing validated: the entry's
# user column carried the build-time ${USERNAME}, which silently names the wrong
# user whenever an editor remaps the runtime one — and the job then no-ops
# forever with no error. These tests assert the shape of the emitted crontab, so
# the binding cannot come back unnoticed.
#
# They read the Dockerfile rather than a built image (the same static approach
# tests/unit/test_bindfs.sh takes for its Dockerfile invariants), so they stay
# in the no-Docker unit tier.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace FS Health Cron Entry Tests"

DOCKERFILE="$PROJECT_ROOT/Dockerfile"

# The cron entry is written by a single `printf '%s\n' ... > /etc/cron.d/...`
# RUN block. Extract that block so assertions are scoped to it rather than
# matching similar text elsewhere in the Dockerfile.
# Anchored on the RUN that opens the block, not on the cron.d path — the path
# first appears in the closing redirect, which would clip everything above it.
cron_block() {
    /usr/bin/awk '/^RUN if command -v cron/ { found=1 }
         found { print }
         found && /^    fi$/ { exit }' "$DOCKERFILE"
}

# The schedule line itself: five time fields, a user column, then the command.
# Deliberately quote-agnostic — a `"17 ...${USERNAME}..."` line is exactly the
# regression under test, so a single-quote-only match would skip it and let the
# assertions below pass on an empty string.
schedule_line() {
    cron_block | /usr/bin/grep -E "^[[:space:]]*['\"]17 \* \* \* \*" || true
}

# The schedule line with its surrounding quoting stripped, so field positions
# are stable regardless of which quote style the Dockerfile used.
schedule_line_unquoted() {
    schedule_line | command sed "s/^[[:space:]]*['\"]//; s/['\"][[:space:]]*\\\\\?[[:space:]]*$//"
}

# ============================================================================
# Test: the entry exists at all
# ============================================================================
test_cron_entry_written() {
    assert_file_contains "$DOCKERFILE" "/etc/cron.d/workspace-fs-health" \
        "Dockerfile writes the workspace-fs-health cron entry"

    local line
    line=$(schedule_line)
    assert_not_empty "$line" \
        "Cron entry has an hourly schedule line at minute 17"
}

# ============================================================================
# Test: user column is root, not a build-time username (issue #800)
# ============================================================================
test_user_column_is_root() {
    local user_column
    # Field 6 — the user column that follows the five time fields.
    user_column=$(schedule_line_unquoted | /usr/bin/awk '{ print $6 }')

    assert_equals "root" "$user_column" \
        "Cron user column must be root (the wrapper drops to the resolved user)"
}

test_user_column_not_build_time_username() {
    # The actual #800 regression: a build-time ${USERNAME} here expands to a
    # user that EXISTS but may not be the runtime one, so cron runs the job
    # successfully as the wrong user, it finds no env snapshot under that HOME,
    # and it exits 0 having repaired nothing. Silent, not loud.
    local line
    line=$(schedule_line)
    assert_not_contains "$line" 'USERNAME' \
        "Cron user column must not bake the build-time USERNAME (issue #800)"
}

test_entry_invokes_the_wrapper() {
    local line
    line=$(schedule_line)
    assert_contains "$line" "/usr/local/bin/workspace-fs-health-cron" \
        "Cron entry invokes the fs-health cron wrapper"
}

# ============================================================================
# Test: output is discoverable
# ============================================================================
test_mailto_is_silenced() {
    # These images ship no MTA, so without MAILTO="" cron's default mail
    # delivery discards the one signal worth seeing.
    local block
    block=$(cron_block)
    assert_contains "$block" 'MAILTO=""' \
        "Cron entry sets MAILTO=\"\" (no MTA in these images)"
}

test_output_routed_to_log_file() {
    local line
    line=$(schedule_line)
    assert_contains "$line" ">> /var/log/workspace-fs-health.log" \
        "Cron entry appends output to a durable log file"
    assert_contains "$line" "2>&1" \
        "Cron entry captures stderr too (the script reports on stderr)"
}

test_output_not_piped_to_logger() {
    # These images ship no syslog daemon, so there is no /dev/log for logger to
    # write to — it would discard the message AND still exit 0, recreating the
    # silent-failure class this entry exists to fix. A pipe would also mask the
    # job's exit status from cron, since cron sees only the last stage.
    local line
    line=$(schedule_line)
    assert_not_contains "$line" "logger" \
        "Cron entry must not pipe to logger (no syslog daemon in these images)"
    assert_not_contains "$line" "|" \
        "Cron entry must not use a pipeline (it would mask the job's exit status)"
}

test_log_file_is_created() {
    # cron's `>>` cannot create a file in /var/log as a non-root job would need,
    # and an absent file makes the first run's output vanish — create it at
    # build time alongside the entry.
    local block
    block=$(cron_block)
    assert_contains "$block" "touch /var/log/workspace-fs-health.log" \
        "Build creates the log file the cron entry appends to"
    assert_contains "$block" "chmod 640 /var/log/workspace-fs-health.log" \
        "Log file is mode 640 (not world-readable)"
}

# ============================================================================
# Test: file mode
# ============================================================================
test_entry_mode_is_644() {
    # cron refuses to run a /etc/cron.d file that is group- or world-writable.
    local block
    block=$(cron_block)
    assert_contains "$block" "chmod 644 /etc/cron.d/workspace-fs-health" \
        "Cron entry is installed mode 644 (cron ignores writable files)"
}

# ============================================================================
# Test: guarded on the cron feature
# ============================================================================
test_entry_guarded_on_cron_installed() {
    local block
    block=$(cron_block)
    assert_contains "$block" "command -v cron" \
        "Cron entry is only written when the cron feature is installed"
}

# Run tests
run_test test_cron_entry_written "Cron entry is written with an hourly schedule"
run_test test_user_column_is_root "User column is root"
run_test test_user_column_not_build_time_username "User column has no build-time USERNAME (issue #800)"
run_test test_entry_invokes_the_wrapper "Entry invokes the fs-health cron wrapper"
run_test test_mailto_is_silenced "MAILTO is silenced"
run_test test_output_routed_to_log_file "Output is routed to a log file"
run_test test_output_not_piped_to_logger "Output is not piped to logger"
run_test test_log_file_is_created "Log file is created at build time"
run_test test_entry_mode_is_644 "Entry is installed mode 644"
run_test test_entry_guarded_on_cron_installed "Entry is guarded on cron being installed"

# Generate test report
generate_report
