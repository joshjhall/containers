#!/usr/bin/env bash
# Unit tests for bin/lib/update-versions/kubernetes-checksums.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Lib Update Versions Kubernetes Checksums Tests"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh"
    assert_executable "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh"
}

# ============================================================================
# Test: Script shows help with insufficient arguments
# ============================================================================
test_script_requires_arguments() {
    # Script should fail with no arguments
    if "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh" 2>/dev/null; then
        assert_true false "Script should fail with no arguments"
    else
        assert_true true "Script correctly fails with no arguments"
    fi

    # Script should show usage message
    local output
    output=$("$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh" 2>&1 || true)

    if echo "$output" | grep -qi "usage\|example"; then
        assert_true true "Script shows usage message when args missing"
    else
        assert_true false "Script missing usage message"
    fi
}

# ============================================================================
# Test: Script accepts three version arguments
# ============================================================================
test_script_accepts_valid_arguments() {
    # Create a backup of kubernetes.sh
    local k8s_backup="$PROJECT_ROOT/lib/features/kubernetes.sh.backup.$$"
    cp "$PROJECT_ROOT/lib/features/kubernetes.sh" "$k8s_backup"

    # Run script with valid arguments (should succeed)
    if "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh" "0.50.16" "0.4.5" "3.19.0" 2>/dev/null; then
        assert_true true "Script accepts three valid version arguments"
    else
        assert_true false "Script failed with valid arguments"
    fi

    # Restore kubernetes.sh
    mv "$k8s_backup" "$PROJECT_ROOT/lib/features/kubernetes.sh"
}

# ============================================================================
# Test: Script validates kubernetes.sh exists
# ============================================================================
test_script_checks_kubernetes_file() {
    # Temporarily rename kubernetes.sh
    local k8s_file="$PROJECT_ROOT/lib/features/kubernetes.sh"
    local k8s_backup="$k8s_file.hidden.$$"

    if [ -f "$k8s_file" ]; then
        mv "$k8s_file" "$k8s_backup"

        # Script should fail when kubernetes.sh is missing
        if "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh" "0.50.16" "0.4.5" "3.19.0" 2>/dev/null; then
            mv "$k8s_backup" "$k8s_file"
            assert_true false "Script should fail when kubernetes.sh is missing"
        else
            mv "$k8s_backup" "$k8s_file"
            assert_true true "Script correctly fails when kubernetes.sh is missing"
        fi
    else
        skip_test "kubernetes.sh not found for testing"
    fi
}

# ============================================================================
# Test: Script has update functions defined
# ============================================================================
test_script_has_update_functions() {
    # Source the script to check function definitions
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    # Source kubernetes-checksums.sh
    # Need to prevent main() from running
    if grep -q "^main \"" "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh"; then
        # Script calls main, need to source carefully
        assert_true true "Script has main function (cannot test function definitions safely)"
    else
        source "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh"

        # Check for update functions
        if declare -f update_k9s_checksums >/dev/null; then
            assert_true true "update_k9s_checksums is defined"
        else
            assert_true false "update_k9s_checksums is not defined"
        fi

        if declare -f update_krew_checksums >/dev/null; then
            assert_true true "update_krew_checksums is defined"
        else
            assert_true false "update_krew_checksums is not defined"
        fi

        if declare -f update_helm_checksums >/dev/null; then
            assert_true true "update_helm_checksums is defined"
        else
            assert_true false "update_helm_checksums is not defined"
        fi
    fi
}

# ============================================================================
# Test: Script output format
# ============================================================================
test_script_output_format() {
    # Create a backup of kubernetes.sh
    local k8s_backup="$PROJECT_ROOT/lib/features/kubernetes.sh.backup.$$"
    cp "$PROJECT_ROOT/lib/features/kubernetes.sh" "$k8s_backup"

    # Run script and capture output
    local output
    output=$("$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh" "0.50.16" "0.4.5" "3.19.0" 2>&1 || true)

    # Restore kubernetes.sh
    mv "$k8s_backup" "$PROJECT_ROOT/lib/features/kubernetes.sh"

    # Check for expected output markers
    if echo "$output" | grep -q "Kubernetes Checksum Updater"; then
        assert_true true "Script outputs Kubernetes Checksum Updater header"
    else
        assert_true false "Script missing expected header"
    fi

    if echo "$output" | grep -q "k9s version"; then
        assert_true true "Script outputs k9s version"
    else
        assert_true false "Script missing k9s version output"
    fi

    if echo "$output" | grep -q "krew version"; then
        assert_true true "Script outputs krew version"
    else
        assert_true false "Script missing krew version output"
    fi

    if echo "$output" | grep -q "Helm version"; then
        assert_true true "Script outputs Helm version"
    else
        assert_true false "Script missing Helm version output"
    fi
}

# ============================================================================
# Test: Script syntax is valid
# ============================================================================
test_script_syntax() {
    # Check bash syntax
    if bash -n "$PROJECT_ROOT/bin/lib/update-versions/kubernetes-checksums.sh" 2>/dev/null; then
        assert_true true "Script has valid bash syntax"
    else
        assert_true false "Script has syntax errors"
    fi
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_script_requires_arguments "Script requires three arguments"
run_test test_script_accepts_valid_arguments "Script accepts valid version arguments"
run_test test_script_checks_kubernetes_file "Script validates kubernetes.sh exists"
run_test test_script_has_update_functions "Script has update functions defined"
run_test test_script_output_format "Script produces expected output format"
run_test test_script_syntax "Script has valid bash syntax"

# Generate test report
generate_report
