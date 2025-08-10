#!/bin/bash
# Check R development tools installation logs
#
# This script displays the summary of R package installations,
# including any errors or warnings that occurred during the build.
#
# Usage:
#   check-r-dev-logs.sh [options]
#
# Options:
#   -s, --summary    Show only the summary (default)
#   -e, --errors     Show all errors and warnings
#   -f, --full       Show the full installation log
#   -h, --help       Show this help message
#

set -euo pipefail

LOG_DIR="/var/log/r-dev-install"
LOG_FILE="$LOG_DIR/installation.log"
ERROR_LOG="$LOG_DIR/errors.log"
SUMMARY_LOG="$LOG_DIR/summary.log"

# Default action
ACTION="summary"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--summary)
            ACTION="summary"
            shift
            ;;
        -e|--errors)
            ACTION="errors"
            shift
            ;;
        -f|--full)
            ACTION="full"
            shift
            ;;
        -h|--help)
            echo "Usage: check-r-dev-logs.sh [options]"
            echo ""
            echo "Options:"
            echo "  -s, --summary    Show only the summary (default)"
            echo "  -e, --errors     Show all errors and warnings"
            echo "  -f, --full       Show the full installation log"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

# Check if logs exist
if [ ! -d "$LOG_DIR" ]; then
    echo "No R development tools installation logs found."
    echo "The logs are created when R-dev tools are installed during container build."
    exit 0
fi

case $ACTION in
    summary)
        if [ -f "$SUMMARY_LOG" ]; then
            echo "=== R Development Tools Installation Summary ==="
            cat "$SUMMARY_LOG"
        else
            echo "No summary log found at $SUMMARY_LOG"
        fi
        ;;
    
    errors)
        if [ -f "$ERROR_LOG" ]; then
            echo "=== R Development Tools Installation Errors/Warnings ==="
            if [ -s "$ERROR_LOG" ]; then
                cat "$ERROR_LOG"
                echo ""
                echo "Total errors: $(grep -c -i "error" "$ERROR_LOG" 2>/dev/null || echo "0")"
                echo "Total warnings: $(grep -c -i "warning" "$ERROR_LOG" 2>/dev/null || echo "0")"
            else
                echo "No errors or warnings found!"
            fi
        else
            echo "No error log found at $ERROR_LOG"
        fi
        ;;
    
    full)
        if [ -f "$LOG_FILE" ]; then
            echo "=== Full R Development Tools Installation Log ==="
            echo "Warning: This log is very long. Consider using 'less' or redirecting to a file."
            echo "Press Enter to continue or Ctrl+C to cancel..."
            read -r
            cat "$LOG_FILE"
        else
            echo "No installation log found at $LOG_FILE"
        fi
        ;;
esac

echo ""
echo "Log files location: $LOG_DIR"