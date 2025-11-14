#!/bin/bash
# Check container build logs for all features
#
# This script displays summaries and logs from feature installations
# that occurred during the container build process.
#
# Usage:
#   check-build-logs.sh [options] [feature]
#
# Options:
#   -s, --summary     Show summary for all features (default)
#   -e, --errors      Show all errors and warnings
#   -f, --full        Show the full installation log
#   -l, --list        List available feature logs
#   -h, --help        Show this help message
#
# Examples:
#   check-build-logs.sh              # Show summary of all features
#   check-build-logs.sh python       # Show summary for Python
#   check-build-logs.sh -e node      # Show errors for Node.js
#   check-build-logs.sh -f rust      # Show full log for Rust
#

set -euo pipefail

# Use BUILD_LOG_DIR if set, otherwise try /var/log, fallback to /tmp
if [ -n "${BUILD_LOG_DIR:-}" ]; then
    LOG_DIR="$BUILD_LOG_DIR"
elif [ -d "/var/log/container-build" ]; then
    LOG_DIR="/var/log/container-build"
elif [ -d "/tmp/container-build" ]; then
    LOG_DIR="/tmp/container-build"
else
    # Default to /var/log path (may not exist in all environments)
    LOG_DIR="/var/log/container-build"
fi

ACTION="summary"
FEATURE=""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
# YELLOW='\033[1;33m'  # Currently unused
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
        -l|--list)
            ACTION="list"
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: check-build-logs.sh [options] [feature]

Options:
  -s, --summary     Show summary for all features (default)
  -e, --errors      Show all errors and warnings
  -f, --full        Show the full installation log
  -l, --list        List available feature logs
  -h, --help        Show this help message

Examples:
  check-build-logs.sh              # Show summary of all features
  check-build-logs.sh python       # Show summary for Python
  check-build-logs.sh -e node      # Show errors for Node.js
  check-build-logs.sh -f rust      # Show full log for Rust
EOF
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
        *)
            # Assume it's a feature name
            FEATURE="$1"
            shift
            ;;
    esac
done

# Check if logs exist
if [ ! -d "$LOG_DIR" ]; then
    echo "No build logs found."
    echo "Build logs are created during container image construction."
    exit 0
fi

# Function to display a single feature's information
show_feature() {
    local feature="$1"
    local action="$2"
    local summary_file="${LOG_DIR}/${feature}-summary.log"
    local error_file="${LOG_DIR}/${feature}-errors.log"
    local log_file="${LOG_DIR}/${feature}-install.log"
    
    case $action in
        summary)
            if [ -f "$summary_file" ]; then
                echo -e "${BLUE}=== ${feature} ===${NC}"
                cat "$summary_file"
                echo ""
            fi
            ;;
        
        errors)
            if [ -f "$error_file" ]; then
                echo -e "${BLUE}=== ${feature} Errors/Warnings ===${NC}"
                if [ -s "$error_file" ]; then
                    cat "$error_file"
                else
                    echo -e "${GREEN}No errors or warnings found!${NC}"
                fi
                echo ""
            fi
            ;;
        
        full)
            if [ -f "$log_file" ]; then
                echo -e "${BLUE}=== ${feature} Full Log ===${NC}"
                echo "Warning: This log may be very long. Press Enter to continue or Ctrl+C to cancel..."
                read -r
                cat "$log_file"
            else
                echo "No log file found for $feature"
            fi
            ;;
    esac
}

# Main logic
case $ACTION in
    list)
        echo -e "${BLUE}=== Available Feature Logs ===${NC}"
        for log in "$LOG_DIR"/*-install.log; do
            [ -f "$log" ] || continue
            feature=$(basename "$log" -install.log)
            echo "  - $feature"
        done
        ;;
    
    summary|errors|full)
        if [ -n "$FEATURE" ]; then
            # Show specific feature
            feature_log=$(find "$LOG_DIR" -name "*${FEATURE}*-install.log" 2>/dev/null | head -1)
            if [ -n "$feature_log" ]; then
                feature=$(basename "$feature_log" -install.log)
                show_feature "$feature" "$ACTION"
            else
                echo "No logs found for feature: $FEATURE"
                echo "Note: Feature names are normalized (e.g., 'golang', 'python', 'r-development-tools')"
                echo "Use -l to list available features"
                exit 1
            fi
        else
            # Show all features
            if [ "$ACTION" = "summary" ] && [ -f "$LOG_DIR/master-summary.log" ]; then
                echo -e "${BLUE}=== Container Build Summary ===${NC}"
                echo ""
                printf "%-20s %s\n" "Feature" "Status"
                printf "%-20s %s\n" "-------" "------"
                
                while IFS=: read -r feature status; do
                    feature=$(echo "$feature" | xargs)
                    status=$(echo "$status" | xargs)
                    
                    if echo "$status" | grep -q "0 errors"; then
                        printf "%-20s ${GREEN}✓ %s${NC}\n" "$feature" "$status"
                    else
                        printf "%-20s ${RED}✗ %s${NC}\n" "$feature" "$status"
                    fi
                done < "$LOG_DIR/master-summary.log"
                
                echo ""
                echo "Use 'check-build-logs.sh <feature>' for details"
                echo "Use 'check-build-logs.sh -e' to see all errors"
            else
                # Show individual summaries/errors for all features
                for log in "$LOG_DIR"/*-install.log; do
                    [ -f "$log" ] || continue
                    feature=$(basename "$log" -install.log)
                    show_feature "$feature" "$ACTION"
                done
            fi
        fi
        ;;
esac

echo ""
echo "Log files location: $LOG_DIR"