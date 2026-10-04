#!/usr/bin/env bash
# Unit tests for lib/features/cron.sh
# Tests cron daemon installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Cron Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-cron-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/etc/container/startup"
    mkdir -p "$TEST_TEMP_DIR/etc/container"
    mkdir -p "$TEST_TEMP_DIR/etc/cron.d"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID 2>/dev/null || true
}

# Test: Cron startup script creation
test_cron_startup_script() {
    local startup_dir="$TEST_TEMP_DIR/etc/container/startup"
    local startup_script="$startup_dir/05-cron.sh"

    # Create startup script matching actual cron.sh output
    command cat >"$startup_script" <<'EOF'
#!/bin/bash
# Cron daemon status check
#
# The cron daemon is normally started by the entrypoint while still running
# as root (before dropping to non-root user).

# Check if cron is installed
if ! command -v cron &> /dev/null; then
    exit 0
fi

# Check if cron is already running (started by entrypoint)
if pgrep -x "cron" > /dev/null 2>&1; then
    echo "cron: Daemon running"
    exit 0
fi

# Cron not running - try to start it (fallback)
if [ "$(id -u)" = "0" ]; then
    service cron start > /dev/null 2>&1 || cron
elif command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
    sudo service cron start > /dev/null 2>&1 || sudo cron
fi
EOF
    chmod +x "$startup_script"

    assert_file_exists "$startup_script"

    # Check script is executable
    if [ -x "$startup_script" ]; then
        assert_true true "Cron startup script is executable"
    else
        assert_true false "Cron startup script is not executable"
    fi

    # Check for idempotent check (pgrep)
    if command grep -q "pgrep" "$startup_script"; then
        assert_true true "Startup script checks if cron is already running"
    else
        assert_true false "Startup script missing idempotent check"
    fi

    # Check script mentions entrypoint handles startup
    if command grep -q "entrypoint" "$startup_script"; then
        assert_true true "Startup script documents entrypoint handles cron"
    else
        assert_true false "Startup script should mention entrypoint"
    fi
}

# Test: Cron environment file creation
test_cron_env_file() {
    local env_file="$TEST_TEMP_DIR/etc/container/cron-env"

    # Create environment file matching actual cron.sh output
    command cat >"$env_file" <<'EOF'
#!/bin/bash
# Cron Environment File
# Source this file at the start of cron job scripts

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export HOME="${HOME:-/home/${USER:-root}}"
export WORKING_DIR="${WORKING_DIR:-/workspace}"

# Rust environment (if installed)
if [ -d "/cache/cargo" ]; then
    export CARGO_HOME="/cache/cargo"
    export RUSTUP_HOME="/cache/rustup"
    export PATH="${CARGO_HOME}/bin:${PATH}"
fi

# cargo-sweep discovery roots, decoupled from WORKING_DIR (#678)
export CARGO_SWEEP_ROOTS="${CARGO_SWEEP_ROOTS:-/workspace}"
EOF
    chmod 644 "$env_file"

    assert_file_exists "$env_file"

    # Check for PATH export
    if command grep -q "export PATH=" "$env_file"; then
        assert_true true "Environment file exports PATH"
    else
        assert_true false "Environment file missing PATH export"
    fi

    # Check for CARGO_HOME setup
    if command grep -q "CARGO_HOME" "$env_file"; then
        assert_true true "Environment file includes Rust environment"
    else
        assert_true false "Environment file missing Rust environment"
    fi

    # Check for WORKING_DIR
    if command grep -q "WORKING_DIR" "$env_file"; then
        assert_true true "Environment file includes WORKING_DIR"
    else
        assert_true false "Environment file missing WORKING_DIR"
    fi

    # cargo-sweep discovery roots must be exported independently of WORKING_DIR
    # so the sweep reaches sibling checkouts under /workspace (#678)
    if command grep -q "CARGO_SWEEP_ROOTS" "$env_file"; then
        assert_true true "Environment file includes CARGO_SWEEP_ROOTS"
    else
        assert_true false "Environment file missing CARGO_SWEEP_ROOTS"
    fi
}

# Test: Cron bashrc configuration
test_cron_bashrc() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/10-cron.sh"

    # Create bashrc file matching actual cron.sh output
    command cat >"$bashrc_file" <<'EOF'
# Cron Aliases and Functions
set +u
set +e

if [[ $- != *i* ]]; then
    return 0
fi

# List user's crontab
alias cron-list='crontab -l 2>/dev/null || echo "No crontab for current user"'

# Edit user's crontab
alias cron-edit='crontab -e'

# List system cron jobs
alias cron-system='command ls -la /etc/cron.d/ 2>/dev/null'

# Show cron daemon status
alias cron-status='pgrep -x cron > /dev/null && echo "cron: running" || echo "cron: not running"'
EOF
    chmod +x "$bashrc_file"

    assert_file_exists "$bashrc_file"

    # Check for cron-list alias
    if command grep -q "alias cron-list=" "$bashrc_file"; then
        assert_true true "Bashrc includes cron-list alias"
    else
        assert_true false "Bashrc missing cron-list alias"
    fi

    # Check for cron-status alias
    if command grep -q "alias cron-status=" "$bashrc_file"; then
        assert_true true "Bashrc includes cron-status alias"
    else
        assert_true false "Bashrc missing cron-status alias"
    fi
}

# Test: Cron test script
test_cron_verification_script() {
    local test_script="$TEST_TEMP_DIR/usr/local/bin/test-cron"

    # Create test script matching actual cron.sh output
    command cat >"$test_script" <<'EOF'
#!/bin/bash
echo "=== Cron Status ==="

if command -v cron &> /dev/null; then
    echo "cron: Installed"
else
    echo "cron: Not installed"
    exit 1
fi

echo ""
echo "=== Daemon Status ==="
if pgrep -x "cron" > /dev/null 2>&1; then
    echo "cron daemon: Running"
else
    echo "cron daemon: Not running"
fi
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Test script is executable"
    else
        assert_true false "Test script is not executable"
    fi

    # Check for daemon status check
    if command grep -q "pgrep" "$test_script"; then
        assert_true true "Test script checks daemon status"
    else
        assert_true false "Test script missing daemon status check"
    fi
}

# Test: Startup script numbering (should be early)
test_cron_startup_order() {
    local startup_script="$TEST_TEMP_DIR/etc/container/startup/05-cron.sh"

    # Create the script
    echo "#!/bin/bash" >"$startup_script"
    echo "# Cron startup" >>"$startup_script"
    chmod +x "$startup_script"

    # Extract the number from the filename
    local script_name
    script_name=$(basename "$startup_script")
    local script_num="${script_name%%-*}"

    # Check that cron uses an early number (05)
    if [ "$script_num" = "05" ]; then
        assert_true true "Cron startup uses early number (05)"
    else
        assert_true false "Cron startup number should be 05, got $script_num"
    fi
}

# ============================================================================
# Dockerfile ARG ordering for the cron RUN (#976)
# ============================================================================
#
# A Dockerfile ARG expands empty before its declaration. ARG INCLUDE_BINDFS used
# to be declared just AFTER the cron RUN, so a bindfs-only image never got the
# daemon its /etc/cron.d/fuse-cleanup job needs — silently, since the condition
# just read false. Same check shape as the Node RUN guard in python-dev.sh (#1008).

# Line number of the cron RUN (the first RUN after ARG INCLUDE_CRON).
cron_run_line() {
    command awk '/^ARG INCLUDE_CRON=/{seen=1} seen && /^RUN /{print NR; exit}' "$1"
}

# Print the cron RUN condition as one line (from its RUN to the cron.sh call).
extract_cron_clause() {
    local run_line
    run_line=$(cron_run_line "$1")
    [ -n "$run_line" ] || return 0
    command awk -v run="$run_line" 'NR >= run { print } NR >= run && /cron\.sh/ { exit }' "$1" |
        command tr -d '\\\n'
}

# Print the ARG names the cron RUN condition reads, sorted, space-separated.
cron_condition_vars() {
    extract_cron_clause "$1" |
        command grep -o '\${[A-Z_][A-Z0-9_]*}' |
        command sed -e 's/^\${//' -e 's/}$//' |
        command sort -u |
        command tr '\n' ' ' |
        command sed 's/ $//'
}

# Print one line per ARG the cron RUN reads that is NOT declared between the
# RUN's stage FROM and the RUN itself; prints nothing when all are in scope.
cron_condition_arg_order_errors() {
    local dockerfile="$1"
    local run_line stage_start var decls
    run_line=$(cron_run_line "$dockerfile")
    stage_start=$(command awk -v run="${run_line:-0}" 'NR < run && /^FROM /{last=NR} END{print last+0}' "$dockerfile")
    for var in $(cron_condition_vars "$dockerfile"); do
        if ! command awk -v lo="$stage_start" -v hi="${run_line:-0}" -v re="^ARG ${var}(=|$)" \
            'NR > lo && NR < hi && $0 ~ re {found=1} END{exit !found}' "$dockerfile"; then
            decls=$(command grep -nE "^ARG ${var}(=|$)" "$dockerfile" | command cut -d: -f1 | command tr '\n' ' ' | command sed 's/ $//')
            echo "${var}: declared at line(s) ${decls:-none}, cron RUN at line ${run_line:-none} (stage FROM at line ${stage_start})"
        fi
    done
}

test_cron_condition_args_declared_before_use() {
    local dockerfile="$PROJECT_ROOT/Dockerfile"

    # Pin the derived list so the ordering check cannot go vacuous if the
    # extraction stops matching.
    assert_equals "INCLUDE_BINDFS INCLUDE_CRON INCLUDE_DEV_TOOLS INCLUDE_RUST_DEV" \
        "$(cron_condition_vars "$dockerfile")" \
        "Cron RUN condition reads exactly the expected ARGs"
    assert_equals "" "$(cron_condition_arg_order_errors "$dockerfile")" \
        "Every ARG the cron RUN condition reads is declared in-stage before it"
    assert_equals "1" "$(command grep -c '^ARG INCLUDE_BINDFS=' "$dockerfile")" \
        "INCLUDE_BINDFS is declared exactly once"
}

# Negative control: the pre-#976 layout (ARG INCLUDE_BINDFS just after the cron
# RUN) must be reported, and only that ARG.
test_cron_arg_order_check_catches_late_include_bindfs() {
    local mutated="$TEST_TEMP_DIR/Dockerfile.late-bindfs"
    local errors
    command awk '
        /^ARG INCLUDE_BINDFS=/ { held=$0; next }
        { print }
        /features\/cron\.sh; \\$/ { in_cron=1 }
        in_cron && /^ *fi$/ { print held; in_cron=0 }
    ' "$PROJECT_ROOT/Dockerfile" >"$mutated"

    if command cmp -s "$PROJECT_ROOT/Dockerfile" "$mutated"; then
        assert_true false "Mutation did not change the Dockerfile copy"
    fi
    errors=$(cron_condition_arg_order_errors "$mutated")
    assert_contains "$errors" "INCLUDE_BINDFS: declared at line" \
        "Late ARG INCLUDE_BINDFS is reported"
    assert_not_contains "$errors" "INCLUDE_CRON" "Unmoved INCLUDE_CRON is not reported"
    assert_not_contains "$errors" "INCLUDE_DEV_TOOLS" "Unmoved INCLUDE_DEV_TOOLS is not reported"
    assert_not_contains "$errors" "INCLUDE_RUST_DEV" "Unmoved INCLUDE_RUST_DEV is not reported"
}

# Run tests with setup/teardown wrapper
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_cron_startup_script "Cron startup script creation"
run_test_with_setup test_cron_env_file "Cron environment file"
run_test_with_setup test_cron_bashrc "Cron bashrc configuration"
run_test_with_setup test_cron_verification_script "Cron verification script"
run_test_with_setup test_cron_startup_order "Cron startup script ordering"
run_test_with_setup test_cron_condition_args_declared_before_use "Cron RUN ARGs declared before use (#976)"
run_test_with_setup test_cron_arg_order_check_catches_late_include_bindfs "ARG-order check catches a late INCLUDE_BINDFS"

# Generate report
generate_report
