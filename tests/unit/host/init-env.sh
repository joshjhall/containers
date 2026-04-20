#!/usr/bin/env bash
# Unit tests for host/init-env.sh
# Tests the host-side environment initialization script

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Host init-env.sh Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/host/init-env.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-init-env-$unique_id"
    command mkdir -p "$TEST_TEMP_DIR"

    # Create a fake project structure:
    #   TEST_TEMP_DIR/project/           <- project root
    #   TEST_TEMP_DIR/project/containers/ <- containers root (where script lives)
    #   TEST_TEMP_DIR/project/containers/host/ <- script location
    #   TEST_TEMP_DIR/project/.devcontainer/  <- output dir
    command mkdir -p "$TEST_TEMP_DIR/project/containers/host"
    command mkdir -p "$TEST_TEMP_DIR/project/.devcontainer"

    # Copy the script into our fake containers/host/ dir
    command cp "$SOURCE_FILE" "$TEST_TEMP_DIR/project/containers/host/init-env.sh"
    command chmod +x "$TEST_TEMP_DIR/project/containers/host/init-env.sh"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "host/init-env.sh should exist"

    if [ -x "$SOURCE_FILE" ]; then
        pass_test "host/init-env.sh is executable"
    else
        fail_test "host/init-env.sh is not executable"
    fi
}

test_syntax_valid() {
    if bash -n "$SOURCE_FILE" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script uses strict mode"
}

test_has_help_flag() {
    assert_file_contains "$SOURCE_FILE" "\-\-help" \
        "Script supports --help flag"
}

test_has_dry_run_flag() {
    assert_file_contains "$SOURCE_FILE" "\-\-dry-run" \
        "Script supports --dry-run flag"
}

test_has_project_root_flag() {
    assert_file_contains "$SOURCE_FILE" "\-\-project-root" \
        "Script supports --project-root flag"
}

test_uses_command_prefix() {
    # Verify key external commands use command prefix or full paths
    assert_file_contains "$SOURCE_FILE" "command chmod" \
        "Uses command prefix for chmod"
    assert_file_contains "$SOURCE_FILE" "command mkdir" \
        "Uses command prefix for mkdir"
    assert_file_contains "$SOURCE_FILE" "command cp" \
        "Uses command prefix for cp"
}

test_has_op_check() {
    assert_file_contains "$SOURCE_FILE" "command -v op" \
        "Script checks for op CLI availability"
}

test_warns_file_ref() {
    assert_file_contains "$SOURCE_FILE" "FILE_REF" \
        "Script handles FILE_REF variables"
    assert_file_contains "$SOURCE_FILE" "not supported" \
        "Script warns FILE_REF is not supported"
}

test_unsets_sa_token() {
    assert_file_contains "$SOURCE_FILE" "unset OP_SERVICE_ACCOUNT_TOKEN" \
        "Script cleans up OP_SERVICE_ACCOUNT_TOKEN"
}

test_sets_chmod_600() {
    assert_file_contains "$SOURCE_FILE" "chmod 600" \
        "Script sets output file to mode 600"
}

# ============================================================================
# Behavioral Tests
# ============================================================================

test_no_env_init_clean_exit() {
    # No .env.init → exit 0
    local output
    output="$(bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>&1)" || {
        fail_test "Script should exit 0 when no .env.init exists (got non-zero)"
        return
    }
    pass_test "Clean exit when no .env.init"
}

test_literal_values_pass_through() {
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
# A comment
TZ=America/Chicago
ENVIRONMENT=development
DATABASE_URL=postgres://localhost/mydb
EOF

    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    local output_file="$TEST_TEMP_DIR/project/.devcontainer/.env"
    if [ ! -f "$output_file" ]; then
        fail_test "Output file was not created"
        return
    fi

    assert_file_contains "$output_file" "TZ=America/Chicago" \
        "TZ value passed through"
    assert_file_contains "$output_file" "ENVIRONMENT=development" \
        "ENVIRONMENT value passed through"
    assert_file_contains "$output_file" "DATABASE_URL=postgres://localhost/mydb" \
        "DATABASE_URL value passed through"
}

test_comments_preserved() {
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
# This is a comment
KEY=value
EOF

    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    local output_file="$TEST_TEMP_DIR/project/.devcontainer/.env"
    assert_file_contains "$output_file" "# This is a comment" \
        "Comments are preserved in output"
}

test_op_ref_name_derivation() {
    # Test the name derivation logic using --dry-run with a mock op
    # Create a mock op that returns a fixed value
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/op" <<'MOCKEOF'
#!/bin/bash
echo "mock-secret-value"
MOCKEOF
    command chmod +x "$TEST_TEMP_DIR/bin/op"

    # .env.init with OP refs
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
OP_GITHUB_TOKEN_REF=op://Vault/GitHub/token
OP_DATABASE_URL_REF=op://Vault/DB/url
EOF

    # Need OP_SERVICE_ACCOUNT_TOKEN for op resolution
    # Use env -u BASH_ENV to prevent container's bashrc.d from resetting PATH
    local output
    output="$(env -u BASH_ENV PATH="$TEST_TEMP_DIR/bin:$PATH" \
        OP_SERVICE_ACCOUNT_TOKEN="test-token" \
        bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" --dry-run 2>/dev/null)"

    # Check that OP_GITHUB_TOKEN_REF -> GITHUB_TOKEN
    if printf '%s' "$output" | command grep -q "^GITHUB_TOKEN=mock-secret-value"; then
        pass_test "OP_GITHUB_TOKEN_REF correctly derived to GITHUB_TOKEN"
    else
        fail_test "Expected GITHUB_TOKEN=mock-secret-value in output, got: $output"
    fi

    # Check that OP_DATABASE_URL_REF -> DATABASE_URL
    if printf '%s' "$output" | command grep -q "^DATABASE_URL=mock-secret-value"; then
        pass_test "OP_DATABASE_URL_REF correctly derived to DATABASE_URL"
    else
        fail_test "Expected DATABASE_URL=mock-secret-value in output, got: $output"
    fi
}

test_file_ref_warned_and_skipped() {
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
LITERAL=value
OP_GOOGLE_CREDS_FILE_REF=op://Vault/GCP/sa-key.json
EOF

    local stderr_output
    stderr_output="$(bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>&1 1>/dev/null)" || true

    if printf '%s' "$stderr_output" | command grep -qi "skip\|not supported"; then
        pass_test "FILE_REF lines are warned and skipped"
    else
        fail_test "Expected warning about FILE_REF, got: $stderr_output"
    fi

    # Verify the FILE_REF line is NOT in the output
    local output_file="$TEST_TEMP_DIR/project/.devcontainer/.env"
    if [ -f "$output_file" ]; then
        if command grep -q "FILE_REF" "$output_file" 2>/dev/null; then
            fail_test "FILE_REF should not appear in output file"
        else
            pass_test "FILE_REF correctly excluded from output"
        fi
    else
        pass_test "FILE_REF correctly excluded (only literal in output)"
    fi
}

test_backup_numbering() {
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
KEY=value1
EOF

    local devcontainer_dir="$TEST_TEMP_DIR/project/.devcontainer"

    # First run — creates .env
    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    assert_file_exists "$devcontainer_dir/.env" "First .env created"

    # Second run — should create .env.bak
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
KEY=value2
EOF
    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    assert_file_exists "$devcontainer_dir/.env.bak" "First backup .env.bak created"

    # Third run — should create .env.bak-2
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
KEY=value3
EOF
    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    assert_file_exists "$devcontainer_dir/.env.bak-2" "Second backup .env.bak-2 created"

    # Fourth run — should create .env.bak-3
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
KEY=value4
EOF
    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    assert_file_exists "$devcontainer_dir/.env.bak-3" "Third backup .env.bak-3 created"
}

test_devcontainer_dir_created_if_missing() {
    # Remove .devcontainer dir
    command rm -rf "$TEST_TEMP_DIR/project/.devcontainer"

    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
KEY=value
EOF

    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    assert_dir_exists "$TEST_TEMP_DIR/project/.devcontainer" \
        ".devcontainer directory created"
    assert_file_exists "$TEST_TEMP_DIR/project/.devcontainer/.env" \
        ".env file created inside"
}

test_output_file_permissions() {
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
SECRET=value
EOF

    bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>/dev/null

    local output_file="$TEST_TEMP_DIR/project/.devcontainer/.env"
    local perms
    perms="$(command stat -c '%a' "$output_file" 2>/dev/null || command stat -f '%Lp' "$output_file" 2>/dev/null)"

    if [ "$perms" = "600" ]; then
        pass_test "Output file has 600 permissions"
    else
        fail_test "Expected 600 permissions, got $perms"
    fi
}

test_op_not_required_without_refs() {
    # .env.init with only literal values — should not need op
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
LITERAL_VAR=hello
ANOTHER=world
EOF

    # Ensure op is NOT on PATH (use isolated PATH)
    local output
    output="$(PATH="/usr/bin:/bin" bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" 2>&1)" || {
        fail_test "Script should not require op when no OP_*_REF lines exist"
        return
    }
    pass_test "op CLI not required when no OP_*_REF lines present"
}

test_dry_run_no_file_written() {
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
KEY=value
EOF

    # Remove existing .env if any
    command rm -f "$TEST_TEMP_DIR/project/.devcontainer/.env"

    local output
    output="$(bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" --dry-run 2>/dev/null)"

    if printf '%s' "$output" | command grep -q "KEY=value"; then
        pass_test "Dry-run prints output to stdout"
    else
        fail_test "Dry-run should print KEY=value to stdout, got: $output"
    fi

    if [ -f "$TEST_TEMP_DIR/project/.devcontainer/.env" ]; then
        fail_test "Dry-run should not create output file"
    else
        pass_test "Dry-run does not write file"
    fi
}

test_help_flag() {
    local output
    output="$(bash "$SOURCE_FILE" --help 2>&1)" || true

    if printf '%s' "$output" | command grep -q "Usage"; then
        pass_test "--help shows usage"
    else
        fail_test "Expected usage info from --help, got: $output"
    fi
}

test_quoted_values_stripped() {
    # Justfile recipes often emit `KEY="op://..."`; docker-compose env_file
    # treats the quotes literally, so init-env.sh must strip them before
    # calling `op read`.
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/op" <<'MOCKEOF'
#!/bin/bash
# Echo the exact ref arg so tests can verify no quotes leak through
printf 'got=[%s]' "$2"
MOCKEOF
    command chmod +x "$TEST_TEMP_DIR/bin/op"

    # .env.secrets with double-quoted SA token (common justfile pattern)
    command cat >"$TEST_TEMP_DIR/project/.env.secrets" <<'EOF'
OP_SERVICE_ACCOUNT_TOKEN="sa-token-value"
EOF

    # .env.init with three quoting styles
    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
OP_DOUBLE_REF="op://Vault/Item/double"
OP_SINGLE_REF='op://Vault/Item/single'
OP_BARE_REF=op://Vault/Item/bare
EOF

    local output
    output="$(env -u BASH_ENV PATH="$TEST_TEMP_DIR/bin:$PATH" \
        bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" --dry-run 2>/dev/null)"

    if printf '%s' "$output" | command grep -q '^DOUBLE=got=\[op://Vault/Item/double\]$'; then
        pass_test "Double-quoted ref value is unquoted before op read"
    else
        fail_test "Expected DOUBLE=got=[op://Vault/Item/double], got: $output"
    fi

    if printf '%s' "$output" | command grep -q '^SINGLE=got=\[op://Vault/Item/single\]$'; then
        pass_test "Single-quoted ref value is unquoted before op read"
    else
        fail_test "Expected SINGLE=got=[op://Vault/Item/single], got: $output"
    fi

    if printf '%s' "$output" | command grep -q '^BARE=got=\[op://Vault/Item/bare\]$'; then
        pass_test "Unquoted ref value passes through unchanged"
    else
        fail_test "Expected BARE=got=[op://Vault/Item/bare], got: $output"
    fi
}

test_op_read_failure_continues() {
    # Mock op that fails for one ref and succeeds for another
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/op" <<'MOCKEOF'
#!/bin/bash
case "$2" in
    op://Vault/Bad/ref)
        echo "ERROR: item not found" >&2
        exit 1
        ;;
    *)
        echo "good-value"
        ;;
esac
MOCKEOF
    command chmod +x "$TEST_TEMP_DIR/bin/op"

    command cat >"$TEST_TEMP_DIR/project/.env.init" <<'EOF'
OP_BAD_VAR_REF=op://Vault/Bad/ref
OP_GOOD_VAR_REF=op://Vault/Good/ref
EOF

    # Use env -u BASH_ENV to prevent container's bashrc.d from resetting PATH
    local output
    output="$(env -u BASH_ENV PATH="$TEST_TEMP_DIR/bin:$PATH" \
        OP_SERVICE_ACCOUNT_TOKEN="test-token" \
        bash "$TEST_TEMP_DIR/project/containers/host/init-env.sh" \
        --project-root "$TEST_TEMP_DIR/project" --dry-run 2>/dev/null)"

    # Good var should be resolved
    if printf '%s' "$output" | command grep -q "^GOOD_VAR=good-value"; then
        pass_test "Successful refs are resolved despite other failures"
    else
        fail_test "Expected GOOD_VAR=good-value in output, got: $output"
    fi

    # Bad var should NOT appear
    if printf '%s' "$output" | command grep -q "^BAD_VAR="; then
        fail_test "Failed ref should not appear in output"
    else
        pass_test "Failed ref correctly excluded from output"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script has valid bash syntax"
run_test test_strict_mode "Script uses strict mode"
run_test test_has_help_flag "Supports --help flag"
run_test test_has_dry_run_flag "Supports --dry-run flag"
run_test test_has_project_root_flag "Supports --project-root flag"
run_test test_uses_command_prefix "Uses command prefix on external commands"
run_test test_has_op_check "Checks for op CLI"
run_test test_warns_file_ref "Handles FILE_REF variables"
run_test test_unsets_sa_token "Cleans up SA token"
run_test test_sets_chmod_600 "Sets chmod 600 on output"

# Behavioral tests
run_test_with_setup test_no_env_init_clean_exit "No .env.init → clean exit"
run_test_with_setup test_literal_values_pass_through "Literal values pass through"
run_test_with_setup test_comments_preserved "Comments preserved in output"
run_test_with_setup test_op_ref_name_derivation "OP_*_REF name derivation"
run_test_with_setup test_file_ref_warned_and_skipped "FILE_REF warned and skipped"
run_test_with_setup test_backup_numbering "Backup numbering works"
run_test_with_setup test_devcontainer_dir_created_if_missing ".devcontainer dir created if missing"
run_test_with_setup test_output_file_permissions "Output file has 600 permissions"
run_test_with_setup test_op_not_required_without_refs "op not required without OP_*_REF"
run_test_with_setup test_dry_run_no_file_written "Dry-run prints to stdout, no file"
run_test_with_setup test_help_flag "--help shows usage"
run_test_with_setup test_op_read_failure_continues "op read failure continues with remaining"
run_test_with_setup test_quoted_values_stripped "Quoted ref values are unquoted before op read"

# Generate test report
generate_report
