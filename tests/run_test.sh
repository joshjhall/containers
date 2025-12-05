#!/usr/bin/env bash
# Single Test Runner for Container Build System
# Usage: ./run_test.sh <test_path>
#
# Examples:
#   ./run_test.sh integration/builds/test_minimal.sh
#   ./run_test.sh unit/features/python.sh

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <test_path>"
    echo ""
    echo "Available test categories:"
    echo "  unit/features/     - Individual feature tests"
    echo "  unit/base/         - Base system tests"
    echo "  integration/builds/ - Build integration tests"
    echo "  integration/devcontainer/ - VS Code devcontainer tests"
    echo "  performance/       - Performance benchmarks"
    echo ""
    echo "Example:"
    echo "  $0 integration/builds/test_minimal.sh"
    exit 1
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_PATH="$1"

# Check if test file exists
if [ ! -f "$TESTS_DIR/$TEST_PATH" ]; then
    echo "Error: Test file not found: $TESTS_DIR/$TEST_PATH"
    exit 1
fi

# Make sure test is executable
chmod +x "$TESTS_DIR/$TEST_PATH"

# Run the test
echo "Running test: $TEST_PATH"
echo "=========================================="
exec "$TESTS_DIR/$TEST_PATH"
