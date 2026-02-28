#!/bin/bash
# Shell Completion Test Utility
#
# Tests that shell completions are properly installed and functional.
# Run this inside a container to verify completion setup.
#
# Usage:
#   ./test-completions.sh                    # Test all detected completions
#   ./test-completions.sh --tool kubectl     # Test specific tool
#   ./test-completions.sh --verbose          # Detailed output
#   ./test-completions.sh --list             # List available completions

set -euo pipefail

# Configuration
VERBOSE=false
SPECIFIC_TOOL=""
LIST_ONLY=false
EXIT_CODE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --tool|-t)
            SPECIFIC_TOOL="$2"
            shift 2
            ;;
        --list|-l)
            LIST_ONLY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--tool NAME] [--list]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v      Show detailed output"
            echo "  --tool, -t NAME    Test specific tool completion"
            echo "  --list, -l         List available completions"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    if [ "$VERBOSE" = "true" ]; then
        echo "[INFO] $1"
    fi
}

log_pass() {
    echo "[PASS] $1"
}

log_fail() {
    echo "[FAIL] $1" >&2
    EXIT_CODE=1
}

log_warn() {
    echo "[WARN] $1"
}

# List available completions
list_completions() {
    echo "Available shell completions:"
    echo ""

    # Static completions in bash_completion.d
    if [ -d /etc/bash_completion.d ]; then
        for file in /etc/bash_completion.d/*; do
            if [ -f "$file" ]; then
                echo "  - $(basename "$file") (static)"
            fi
        done
    fi

    # Dynamic completions from bashrc.d
    if [ -d /etc/bashrc.d ]; then
        for file in /etc/bashrc.d/*; do
            if [ -f "$file" ] && command grep -q "completion" "$file" 2>/dev/null; then
                echo "  - $(basename "$file") (dynamic)"
            fi
        done
    fi

    # Tools that support completion command
    echo ""
    echo "Tools with built-in completion support:"
    for tool in kubectl helm docker docker-compose terraform gh aws gcloud; do
        if command -v "$tool" &>/dev/null; then
            if "$tool" completion bash &>/dev/null 2>&1 || \
               "$tool" --completion bash &>/dev/null 2>&1; then
                echo "  - $tool"
            fi
        fi
    done
}

# Test a specific tool's completion
test_tool_completion() {
    local tool="$1"

    log_info "Testing completion for: $tool"

    # Check if tool exists
    if ! command -v "$tool" &>/dev/null; then
        log_warn "$tool is not installed"
        return 0
    fi

    # Check if tool supports completion generation
    local completion_output
    if completion_output=$("$tool" completion bash 2>/dev/null); then
        log_info "$tool supports 'completion bash' command"
    elif completion_output=$("$tool" --completion bash 2>/dev/null); then
        log_info "$tool supports '--completion bash' flag"
    else
        log_info "$tool may use static completion files"
        return 0
    fi

    # Validate completion output
    local size=${#completion_output}

    if [ "$size" -lt 50 ]; then
        log_fail "$tool completion output too small ($size chars)"
        return 1
    fi

    if [ "$size" -gt 100000 ]; then
        log_fail "$tool completion output too large ($size chars)"
        return 1
    fi

    # Check for dangerous patterns (matches safe_eval blocklist from lib/base/logging.sh)
    local blocklist='rm -rf|curl.*bash|\bwget\b|;\s*rm|\$\(.*rm|exec\s+[^$]|/bin/sh.*-c|bash.*-c.*http|\bmkfifo\b|\bnc\b|\bncat\b|\bchmod\b.*\+s|\bpython[23]?\b.*-c|\bperl\b.*-e'
    if echo "$completion_output" | command grep -qE "$blocklist"; then
        log_fail "$tool completion contains dangerous patterns"
        return 1
    fi

    # Try to source completion in subshell
    if bash -c "eval \"$completion_output\"" 2>/dev/null; then
        log_pass "$tool completion loads without errors"
    else
        log_fail "$tool completion failed to load"
        return 1
    fi

    return 0
}

# Test all detected tool completions
test_all_completions() {
    local tools_tested=0
    local tools_passed=0

    echo "Testing shell completions..."
    echo ""

    # List of common tools to test
    local tools=(
        kubectl helm k9s
        docker docker-compose
        terraform terragrunt tflint
        gh
        aws
        gcloud
        cargo rustup
        npm yarn pnpm
        pip poetry
        go
        ruby gem bundle
    )

    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            ((tools_tested++))
            if test_tool_completion "$tool"; then
                ((tools_passed++))
            fi
        fi
    done

    echo ""
    echo "Completion tests: $tools_passed/$tools_tested passed"

    if [ "$tools_passed" -ne "$tools_tested" ]; then
        EXIT_CODE=1
    fi
}

# Test bashrc.d scripts syntax
test_bashrc_scripts() {
    log_info "Checking bashrc.d scripts..."

    local scripts_checked=0
    local scripts_valid=0

    if [ -d /etc/bashrc.d ]; then
        for script in /etc/bashrc.d/*.sh; do
            if [ -f "$script" ]; then
                ((scripts_checked++))
                if bash -n "$script" 2>/dev/null; then
                    ((scripts_valid++))
                    log_info "Valid syntax: $(basename "$script")"
                else
                    log_fail "Invalid syntax: $(basename "$script")"
                fi
            fi
        done
    fi

    if [ "$scripts_checked" -gt 0 ]; then
        echo "Bashrc.d scripts: $scripts_valid/$scripts_checked valid syntax"
    fi
}

# Main execution
if [ "$LIST_ONLY" = "true" ]; then
    list_completions
elif [ -n "$SPECIFIC_TOOL" ]; then
    test_tool_completion "$SPECIFIC_TOOL"
else
    test_all_completions
    echo ""
    test_bashrc_scripts
fi

# Exit with appropriate code
if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    echo "All completion tests passed"
    exit 0
else
    echo ""
    echo "Some completion tests failed"
    exit 1
fi
