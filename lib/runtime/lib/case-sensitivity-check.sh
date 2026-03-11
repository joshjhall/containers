#!/bin/bash
# Case-insensitive filesystem detection and warning
#
# Detects case-insensitive mounts (common on macOS/Windows hosts) and
# displays a warning with recommendations. Opt-out via SKIP_CASE_CHECK=true.

# Prevent multiple sourcing
if [ -n "${_CASE_SENSITIVITY_CHECK_LOADED:-}" ]; then
    return 0
fi
_CASE_SENSITIVITY_CHECK_LOADED=1

check_case_sensitivity() {
    if [ "${SKIP_CASE_CHECK:-false}" != "true" ] && [ -f "/usr/local/bin/detect-case-sensitivity.sh" ]; then
        # Check if /workspace exists and is writable
        if [ -d "/workspace" ] && [ -w "/workspace" ]; then
            # Run detection in quiet mode, capture exit code
            if ! QUIET=true /usr/local/bin/detect-case-sensitivity.sh /workspace; then
                # Case-insensitive filesystem detected
                echo ""
                echo "======================================================================"
                echo "  ⚠ Case-Insensitive Filesystem Detected"
                echo "======================================================================"
                echo ""
                echo "The /workspace directory is mounted from a case-insensitive filesystem."
                echo "This can cause issues with:"
                echo "  - Git case-only renames (e.g., README.md → readme.md)"
                echo "  - Case-sensitive imports (Python, Go, etc.)"
                echo "  - Build tools expecting exact case matches"
                echo ""
                echo "Platform: Likely macOS or Windows host"
                echo "Container: Linux (expects case-sensitive filesystems)"
                echo ""
                echo "Recommendations:"
                echo "  1. Use case-sensitive APFS volume (macOS)"
                echo "  2. Use WSL2 filesystem (Windows)"
                echo "  3. Use Docker volumes instead of bind mounts"
                echo "  4. Follow strict naming conventions"
                echo ""
                echo "For detailed solutions, see:"
                echo "  docs/troubleshooting/case-sensitive-filesystems.md"
                echo ""
                echo "To disable this check, set: SKIP_CASE_CHECK=true"
                echo "======================================================================"
                echo ""
            fi
        fi
    fi
}
