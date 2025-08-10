#!/usr/bin/env bash
# Test runner wrapper that ensures correct build context
# This script should be run from the parent directory of containers/

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERS_DIR="$(dirname "$SCRIPT_DIR")"

# Check if we're in the right directory
if [ ! -d "containers" ] || [ ! -f "containers/Dockerfile" ]; then
    echo "Error: This script must be run from the parent directory of containers/"
    echo "Current directory: $(pwd)"
    echo ""
    echo "Usage:"
    echo "  cd /path/to/project  # Where 'containers' is a subdirectory"
    echo "  ./containers/bin/test-container-builds.sh"
    exit 1
fi

# Run the test with correct paths
if [ $# -eq 0 ]; then
    # Run all tests
    exec "$CONTAINERS_DIR/tests/run_all.sh"
else
    # Run specific test
    exec "$CONTAINERS_DIR/tests/run_test.sh" "$@"
fi