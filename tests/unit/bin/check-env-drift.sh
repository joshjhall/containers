#!/usr/bin/env bash
# Unit tests for bin/check-env-drift.sh
# Exercises the script against synthetic .env / .env.example fixtures in
# TEST_TEMP_DIR (no Docker, no real project files touched).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

SKIP_DOCKER_CHECK=true init_test_framework

test_suite "Bin Check Env Drift Tests"

# Resolve the script under test relative to this test file so the suite runs
# from any cwd.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_REAL="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$PROJECT_ROOT_REAL/bin/check-env-drift.sh"

run_script() {
    # Point the script at the current TEST_TEMP_DIR (set by framework setup)
    # and capture stdout+stderr. Returns the script's exit code.
    CHECK_ENV_DRIFT_ROOT="$TEST_TEMP_DIR" "$SCRIPT" "$@"
}

test_script_exists_and_executable() {
    assert_file_exists "$SCRIPT" "check-env-drift.sh exists"
    assert_executable "$SCRIPT" "check-env-drift.sh is executable"
}

test_in_sync_pair_passes() {
    /usr/bin/cat >"$TEST_TEMP_DIR/.env" <<'EOF'
FOO=bar
BAZ=qux
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.example" <<'EOF'
# FOO=placeholder
# BAZ=placeholder
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    run_script >/dev/null 2>&1
    assert_true $? "In-sync pair should exit 0"
}

test_duplicate_key_in_example_fails() {
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.example" <<'EOF'
# FOO=placeholder
# FOO=other
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    run_script >/dev/null 2>&1
    assert_false $? "Duplicate key in example should exit non-zero"
}

test_secret_leak_in_example_fails() {
    # Uncommented value with a real GitHub PAT prefix — the hard fail case.
    # Use a low-entropy x-string to match the `ghp_` prefix without tripping
    # gitleaks on this file (matches the convention in setup-gh.sh tests).
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.example" <<'EOF'
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    run_script >/dev/null 2>&1
    assert_false $? "Real-looking secret in example should exit non-zero"
}

test_commented_secret_is_not_a_leak() {
    # Same prefix, but commented — should NOT trigger the leak check.
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.example" <<'EOF'
# GITHUB_TOKEN=ghp_your_token_here
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    run_script >/dev/null 2>&1
    assert_true $? "Commented secret-prefix should not fail the check"
}

test_missing_key_warns_by_default() {
    # Key in .env, missing from .env.example — default is warning (exit 0).
    /usr/bin/cat >"$TEST_TEMP_DIR/.env" <<'EOF'
FOO=bar
UNDOCUMENTED=x
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.example" <<'EOF'
# FOO=placeholder
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    local output
    output=$(run_script 2>&1)
    local rc=$?
    assert_true $rc "Missing-in-example should exit 0 without --strict"
    assert_contains "$output" "UNDOCUMENTED" "Output mentions the missing key"
    assert_contains "$output" "WARNING" "Output contains a warning"
}

test_missing_key_errors_with_strict() {
    /usr/bin/cat >"$TEST_TEMP_DIR/.env" <<'EOF'
FOO=bar
UNDOCUMENTED=x
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.example" <<'EOF'
# FOO=placeholder
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    run_script --strict >/dev/null 2>&1
    assert_false $? "Missing-in-example should exit non-zero with --strict"
}

test_absent_source_file_is_fine() {
    # .env doesn't exist (fresh clone / CI). Only .env.example is checked for
    # duplicates and leaks; no drift error.
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.example" <<'EOF'
# FOO=placeholder
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    run_script >/dev/null 2>&1
    assert_true $? "Missing source file should be tolerated"
}

test_missing_example_file_fails() {
    # No .env.example at all — hard fail.
    /usr/bin/cat >"$TEST_TEMP_DIR/.env" <<'EOF'
FOO=bar
EOF
    /usr/bin/cat >"$TEST_TEMP_DIR/.env.secrets.example" <<'EOF'
# TOKEN=your_token_here
EOF

    run_script >/dev/null 2>&1
    assert_false $? "Missing .env.example should exit non-zero"
}

test_help_flag() {
    local output
    output=$("$SCRIPT" --help)
    assert_contains "$output" "Usage:" "Help text present"
    assert_contains "$output" "--strict" "Help mentions --strict"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_in_sync_pair_passes "In-sync pair passes cleanly"
run_test test_duplicate_key_in_example_fails "Duplicate keys fail"
run_test test_secret_leak_in_example_fails "Real secret in example fails"
run_test test_commented_secret_is_not_a_leak "Commented secret does not fail"
run_test test_missing_key_warns_by_default "Missing-in-example warns by default"
run_test test_missing_key_errors_with_strict "Missing-in-example errors with --strict"
run_test test_absent_source_file_is_fine "Absent .env is tolerated"
run_test test_missing_example_file_fails "Missing .env.example fails"
run_test test_help_flag "Help flag works"

generate_report
