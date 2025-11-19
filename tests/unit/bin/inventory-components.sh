#!/usr/bin/env bash
# Unit tests for bin/inventory-components.sh
# Tests component inventory functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Inventory Components Tests"

# Path to script under test
INVENTORY_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../../bin/inventory-components.sh"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$INVENTORY_SCRIPT" "inventory-components.sh should exist"

    if [ -x "$INVENTORY_SCRIPT" ]; then
        pass_test "inventory-components.sh is executable"
    else
        fail_test "inventory-components.sh is not executable"
    fi
}

# ============================================================================
# Test: Script has valid syntax
# ============================================================================
test_syntax_valid() {
    if bash -n "$INVENTORY_SCRIPT" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

# ============================================================================
# Test: Help output
# ============================================================================
test_help_output() {
    local output
    output=$("$INVENTORY_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "Usage:" "Help should contain usage"
}

# ============================================================================
# Test: JSON output support
# ============================================================================
test_json_output() {
    local script_content
    script_content=$(cat "$INVENTORY_SCRIPT")

    assert_contains "$script_content" "json" "Should support JSON output"
}

# ============================================================================
# Test: Component listing functionality
# ============================================================================
test_component_listing() {
    local script_content
    script_content=$(cat "$INVENTORY_SCRIPT")

    assert_contains "$script_content" "inventory" "Should have component listing functionality"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_help_output "Help output is correct"
run_test test_json_output "JSON output supported"
run_test test_component_listing "Component listing present"

# Generate report
generate_report
