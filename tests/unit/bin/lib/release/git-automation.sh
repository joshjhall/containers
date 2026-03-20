#!/usr/bin/env bash
# Unit tests for bin/lib/release/git-automation.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Release Git Automation Tests"

# File-based mock call tracking (survives subshells)
MOCK_LOG=""
MOCK_GIT_EXIT_CODE=0

# Helper to set up the release environment
setup_release_env() {
    # Disable color codes for testable output
    RED="" GREEN="" BLUE="" YELLOW="" NC=""
    export RED GREEN BLUE YELLOW NC

    # Default: all automation disabled
    AUTO_COMMIT="${1:-false}"
    AUTO_TAG="${2:-false}"
    AUTO_PUSH="${3:-false}"
    AUTO_GITHUB_RELEASE="${4:-false}"
    export AUTO_COMMIT AUTO_TAG AUTO_PUSH AUTO_GITHUB_RELEASE

    # Set up file-based mock log
    MOCK_LOG="$TEST_TEMP_DIR/git_calls.log"
    : > "$MOCK_LOG"
    export MOCK_LOG
    MOCK_GIT_EXIT_CODE=0
    export MOCK_GIT_EXIT_CODE
}

# ============================================================================
# Test: No git repo — prints warning and returns 0
# ============================================================================
test_git_automation_no_git_repo() {
    setup_release_env "true" "true" "true" "false"

    source "$PROJECT_ROOT/bin/lib/release/git-automation.sh"

    # Run in a temp dir without .git
    local output
    output=$(cd "$TEST_TEMP_DIR" && perform_git_automation "1.0.0" 2>&1)

    assert_contains "$output" "Not a git repository" \
        "Prints git repo warning"
}

# ============================================================================
# Test: Auto-commit calls git add + commit
# ============================================================================
test_git_automation_auto_commit() {
    setup_release_env "true" "false" "false" "false"

    # Create .git dir to pass the git repo check
    mkdir -p "$TEST_TEMP_DIR/.git"

    source "$PROJECT_ROOT/bin/lib/release/git-automation.sh"

    # Override git with file-logging mock
    git() {
        echo "git $*" >> "$MOCK_LOG"
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
            echo "main"
        fi
        return 0
    }
    export -f git

    cd "$TEST_TEMP_DIR" && perform_git_automation "2.0.0" >/dev/null 2>&1

    local calls
    calls=$(/usr/bin/cat "$MOCK_LOG")

    assert_contains "$calls" "git add -A" \
        "Auto-commit calls git add"
    assert_contains "$calls" "git commit -m" \
        "Auto-commit calls git commit"
    assert_contains "$calls" "2.0.0" \
        "Commit message includes version"
}

# ============================================================================
# Test: Auto-push calls git push
# ============================================================================
test_git_automation_auto_push() {
    setup_release_env "false" "false" "true" "false"

    mkdir -p "$TEST_TEMP_DIR/.git"

    source "$PROJECT_ROOT/bin/lib/release/git-automation.sh"

    git() {
        echo "git $*" >> "$MOCK_LOG"
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
            echo "main"
        fi
        return 0
    }
    export -f git

    cd "$TEST_TEMP_DIR" && perform_git_automation "3.0.0" >/dev/null 2>&1

    local calls
    calls=$(/usr/bin/cat "$MOCK_LOG")

    assert_contains "$calls" "git push origin main" \
        "Auto-push calls git push"
}

# ============================================================================
# Test: Push failure exits with error
# ============================================================================
test_git_automation_push_failure() {
    setup_release_env "false" "false" "true" "false"

    mkdir -p "$TEST_TEMP_DIR/.git"

    source "$PROJECT_ROOT/bin/lib/release/git-automation.sh"

    git() {
        echo "git $*" >> "$MOCK_LOG"
        if [ "${1:-}" = "push" ]; then
            return 1
        fi
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
            echo "main"
        fi
        return 0
    }
    export -f git

    # The function calls exit 1 on push failure, so we run in a subshell
    local exit_code=0
    (cd "$TEST_TEMP_DIR" && perform_git_automation "3.0.0" >/dev/null 2>&1) || exit_code=$?

    assert_not_equals "0" "$exit_code" "Push failure causes non-zero exit"
}

# ============================================================================
# Test: Auto-tag after push creates and pushes tag
# ============================================================================
test_git_automation_auto_tag() {
    setup_release_env "false" "true" "true" "false"

    mkdir -p "$TEST_TEMP_DIR/.git"

    source "$PROJECT_ROOT/bin/lib/release/git-automation.sh"

    git() {
        echo "git $*" >> "$MOCK_LOG"
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
            echo "main"
        fi
        return 0
    }
    export -f git

    cd "$TEST_TEMP_DIR" && perform_git_automation "4.0.0" >/dev/null 2>&1

    local calls
    calls=$(/usr/bin/cat "$MOCK_LOG")

    assert_contains "$calls" "git tag -a v4.0.0" \
        "Auto-tag creates annotated tag"
    assert_contains "$calls" "git push origin v4.0.0" \
        "Auto-tag pushes tag to origin"
}

# ============================================================================
# Test: No gh CLI — prints warning
# ============================================================================
test_git_automation_no_gh_cli() {
    setup_release_env "false" "false" "false" "true"

    mkdir -p "$TEST_TEMP_DIR/.git"

    source "$PROJECT_ROOT/bin/lib/release/git-automation.sh"

    git() {
        echo "git $*" >> "$MOCK_LOG"
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
            echo "main"
        fi
        return 0
    }
    export -f git

    # Ensure gh is not found by overriding command -v
    local output
    output=$(
        command() {
            if [ "$1" = "-v" ] && [ "$2" = "gh" ]; then
                return 1
            fi
            builtin command "$@"
        }
        cd "$TEST_TEMP_DIR" && perform_git_automation "5.0.0" 2>&1
    )

    assert_contains "$output" "gh CLI not found" \
        "Prints gh CLI not found warning"
}

# ============================================================================
# Test: Manual steps printed when all automation false
# ============================================================================
test_git_automation_manual_steps() {
    setup_release_env "false" "false" "false" "false"

    mkdir -p "$TEST_TEMP_DIR/.git"

    source "$PROJECT_ROOT/bin/lib/release/git-automation.sh"

    git() {
        echo "git $*" >> "$MOCK_LOG"
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
            echo "main"
        fi
        return 0
    }
    export -f git

    local output
    output=$(cd "$TEST_TEMP_DIR" && perform_git_automation "6.0.0" 2>&1)

    assert_contains "$output" "To complete the release" \
        "Prints manual steps"
    assert_contains "$output" "git add -A" \
        "Prints git add command"
    assert_contains "$output" "git tag -a v6.0.0" \
        "Prints git tag command"
    assert_contains "$output" "git push" \
        "Prints git push command"
}

# Run tests
run_test test_git_automation_no_git_repo "No .git dir prints warning"
run_test test_git_automation_auto_commit "Auto-commit calls git add + commit"
run_test test_git_automation_auto_push "Auto-push calls git push"
run_test test_git_automation_push_failure "Push failure exits with error"
run_test test_git_automation_auto_tag "Auto-tag creates and pushes tag"
run_test test_git_automation_no_gh_cli "No gh CLI prints warning"
run_test test_git_automation_manual_steps "Manual steps printed when automation disabled"

# Generate test report
generate_report
