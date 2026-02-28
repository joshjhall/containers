#!/usr/bin/env bash
# Automatically update outdated versions found by check-versions.sh
set -euo pipefail

# Get script directory and source shared utilities
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BIN_DIR}/lib/common.sh"
source "${BIN_DIR}/lib/version-utils.sh"

# Set project root
PROJECT_ROOT="$(dirname "$BIN_DIR")"

# Allow override for testing
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$PROJECT_ROOT}"

# Parse command line arguments
DRY_RUN=false
AUTO_COMMIT=true
BUMP_VERSION=true
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-commit)
            AUTO_COMMIT=false
            shift
            ;;
        --no-bump)
            BUMP_VERSION=false
            shift
            ;;
        --input)
            INPUT_FILE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --dry-run       Show what would be updated without making changes"
            echo "  --no-commit     Update files but don't commit changes"
            echo "  --no-bump       Don't bump patch version after updates"
            echo "  --input FILE    Use JSON file instead of running check-versions.sh"
            echo "  --help          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Source update_version() function from sub-module
source "${BIN_DIR}/lib/update-versions/updaters.sh"

# Main execution
echo -e "${GREEN}=== Container Version Updater ===${NC}"
echo ""

# Get version data
if [ -n "$INPUT_FILE" ]; then
    echo "Reading version data from $INPUT_FILE..."
    if [ ! -f "$INPUT_FILE" ]; then
        echo -e "${RED}Error: Input file not found: $INPUT_FILE${NC}"
        exit 1
    fi
    VERSION_DATA=$(command cat "$INPUT_FILE")
else
    echo "Running version check..."
    VERSION_DATA=$("$BIN_DIR/check-versions.sh" --json 2>/dev/null)
fi

# Extract outdated tools
OUTDATED=$(echo "$VERSION_DATA" | jq '[.tools[] | select(.status == "outdated")]')
UPDATE_COUNT=$(echo "$OUTDATED" | jq 'length')

if [ "$UPDATE_COUNT" -eq 0 ]; then
    echo -e "${GREEN}All versions are up to date!${NC}"
    exit 0
fi

echo -e "${YELLOW}Found $UPDATE_COUNT outdated version(s)${NC}"
echo ""

# Track if any updates were applied
UPDATES_APPLIED=false

# Track successful updates
SUCCESSFUL_UPDATES=0
FAILED_UPDATES=0

# Process each outdated tool
while IFS= read -r update; do
    TOOL=$(echo "$update" | jq -r '.tool')
    CURRENT=$(echo "$update" | jq -r '.current')
    LATEST=$(echo "$update" | jq -r '.latest')
    FILE=$(echo "$update" | jq -r '.file')

    if update_version "$TOOL" "$CURRENT" "$LATEST" "$FILE"; then
        SUCCESSFUL_UPDATES=$((SUCCESSFUL_UPDATES + 1))
        UPDATES_APPLIED=true
    else
        FAILED_UPDATES=$((FAILED_UPDATES + 1))
    fi
done < <(echo "$OUTDATED" | jq -c '.[]')

echo ""

# Note: Kubernetes tools (k9s, krew, helm) use dynamic checksum fetching
# at build time via register_tool_checksum_fetcher, so no static checksum
# updates are needed here.

# Handle commits and version bump
if [ "$UPDATES_APPLIED" = true ] && [ "$DRY_RUN" = false ]; then
    if [ "$AUTO_COMMIT" = true ]; then
        echo -e "${BLUE}Committing changes...${NC}"

        # Stage changes
        cd "$PROJECT_ROOT"
        git add -A

        # Create commit message with update details
        COMMIT_MSG="chore: Update dependency versions

Updated versions:"
        while IFS= read -r update; do
            TOOL=$(echo "$update" | jq -r '.tool')
            CURRENT=$(echo "$update" | jq -r '.current')
            LATEST=$(echo "$update" | jq -r '.latest')
            COMMIT_MSG="$COMMIT_MSG
- $TOOL: $CURRENT → $LATEST"
        done < <(echo "$OUTDATED" | jq -c '.[]')

        git commit -m "$COMMIT_MSG"
        echo -e "${GREEN}✓ Changes committed${NC}"

        # Bump version if requested
        if [ "$BUMP_VERSION" = true ]; then
            echo ""
            echo -e "${BLUE}Bumping patch version...${NC}"
            echo "y" | "$BIN_DIR/release.sh" patch

            # Commit version bump
            git add -A
            git commit -m "chore: Release patch version with dependency updates

Automated dependency updates applied."
            echo -e "${GREEN}✓ Version bumped${NC}"
        fi
    else
        echo -e "${YELLOW}Changes made but not committed (--no-commit flag set)${NC}"
    fi

    echo ""
    echo -e "${GREEN}=== Update Complete ===${NC}"
    echo "Updates applied: $SUCCESSFUL_UPDATES"
    if [ "$FAILED_UPDATES" -gt 0 ]; then
        echo -e "${YELLOW}Updates skipped (invalid versions): $FAILED_UPDATES${NC}"
    fi
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Dry run complete - no changes made${NC}"
    else
        echo -e "${YELLOW}No updates applied${NC}"
    fi
fi
