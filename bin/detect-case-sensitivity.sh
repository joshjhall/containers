#!/usr/bin/env bash
# Detect Case-Sensitivity Utility
# Version: 1.0.0
#
# Description:
#   Detects whether a filesystem path is case-sensitive or case-insensitive.
#   This is important for cross-platform development where macOS/Windows use
#   case-insensitive filesystems but Linux containers expect case-sensitivity.
#
# Usage:
#   detect-case-sensitivity.sh [path]
#
# Arguments:
#   path - Directory path to check (default: /workspace)
#
# Exit Codes:
#   0 - Path is case-sensitive (safe for Linux development)
#   1 - Path is case-insensitive (may cause issues)
#   2 - Error (path doesn't exist, not writable, etc.)
#
# Examples:
#   detect-case-sensitivity.sh /workspace
#   detect-case-sensitivity.sh /mnt/code
#   detect-case-sensitivity.sh

set -eo pipefail

# Default path to check
CHECK_PATH="${1:-/workspace}"

# Colors for output
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Quiet mode (suppress output, only exit codes)
QUIET=${QUIET:-false}

# ============================================================================
# Output Functions
# ============================================================================

info() {
    if [ "$QUIET" != "true" ]; then
        echo -e "${BLUE}ℹ${NC} $*" >&2
    fi
}

success() {
    if [ "$QUIET" != "true" ]; then
        echo -e "${GREEN}✓${NC} $*" >&2
    fi
}

warning() {
    if [ "$QUIET" != "true" ]; then
        echo -e "${YELLOW}⚠${NC} $*" >&2
    fi
}

error() {
    if [ "$QUIET" != "true" ]; then
        echo -e "${RED}✗${NC} $*" >&2
    fi
}

# ============================================================================
# Validation
# ============================================================================

# Check if path exists
if [ ! -d "$CHECK_PATH" ]; then
    error "Path does not exist: $CHECK_PATH"
    exit 2
fi

# Check if path is writable
if [ ! -w "$CHECK_PATH" ]; then
    error "Path is not writable: $CHECK_PATH"
    error "Cannot create test files to detect case-sensitivity"
    exit 2
fi

# ============================================================================
# Detection Logic
# ============================================================================

# Create unique test file names with timestamp to avoid conflicts
TIMESTAMP=$(date +%s%N 2>/dev/null || date +%s)
TEST_FILE_LOWER="${CHECK_PATH}/.case-test-${TIMESTAMP}-lower"
TEST_FILE_UPPER="${CHECK_PATH}/.CASE-TEST-${TIMESTAMP}-UPPER"

# Cleanup function
cleanup() {
    command rm -f "$TEST_FILE_LOWER" "$TEST_FILE_UPPER" 2>/dev/null || true
}

# Ensure cleanup on exit
trap cleanup EXIT INT TERM

# Create test files
info "Testing case-sensitivity of: $CHECK_PATH"

# Create lowercase test file
if ! touch "$TEST_FILE_LOWER" 2>/dev/null; then
    error "Failed to create test file: $TEST_FILE_LOWER"
    exit 2
fi

# Create uppercase test file
if ! touch "$TEST_FILE_UPPER" 2>/dev/null; then
    error "Failed to create test file: $TEST_FILE_UPPER"
    cleanup
    exit 2
fi

# Count how many test files exist
# shellcheck disable=SC2012
file_count=$(ls -1 "${CHECK_PATH}/.case-test-${TIMESTAMP}"* 2>/dev/null | wc -l)

# Determine case-sensitivity
if [ "$file_count" -ge 2 ]; then
    # Two files exist = case-sensitive
    success "$CHECK_PATH is case-sensitive"

    if [ "$QUIET" != "true" ]; then
        echo ""
        echo "This filesystem treats 'file.txt' and 'FILE.TXT' as different files."
        echo "✅ Safe for Linux container development"
        echo "✅ Git case changes will work correctly"
        echo "✅ Import/require statements are case-sensitive"
    fi

    cleanup
    exit 0
else
    # Only one file exists = case-insensitive
    warning "$CHECK_PATH is case-insensitive"

    if [ "$QUIET" != "true" ]; then
        echo ""
        echo "This filesystem treats 'file.txt' and 'FILE.TXT' as the same file."
        echo "⚠ May cause issues with:"
        echo "  - Git case-only renames (git mv README.md readme.md)"
        echo "  - Case-sensitive imports (Python, Go, etc.)"
        echo "  - Build tools expecting exact case matches"
        echo ""
        echo "Platform detection:"

        # Try to detect platform
        if [ -f /etc/os-release ]; then
            # Linux
            echo "  - Container: Linux (expects case-sensitive)"
            echo "  - Host: Likely macOS or Windows (case-insensitive)"
        elif [ "$(uname)" = "Darwin" ]; then
            # macOS
            echo "  - macOS with case-insensitive APFS (default)"
        elif [ "$(uname)" = "Linux" ]; then
            echo "  - Linux with case-insensitive mount (unusual)"
        fi

        echo ""
        echo "Recommendations:"
        echo "  1. Use case-sensitive APFS volume (macOS)"
        echo "  2. Use WSL2 filesystem (Windows)"
        echo "  3. Use Docker volumes instead of bind mounts"
        echo "  4. Follow careful naming conventions"
        echo ""
        echo "See: docs/troubleshooting/case-sensitive-filesystems.md"
    fi

    cleanup
    exit 1
fi
