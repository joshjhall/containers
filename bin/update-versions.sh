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

# Track successful updates, and failures split by cause. A tool with no case
# in updaters.sh is a very different problem from a malformed upstream version
# — the former means the weekly auto-patch is silently stalling that tool at an
# old version — so they are counted and reported separately (issue #781).
SUCCESSFUL_UPDATES=0
INVALID_VERSIONS=0
MISSING_CASES=0
UPDATE_ERRORS=0
INVALID_VERSION_TOOLS=""
MISSING_CASE_TOOLS=""
ERROR_TOOLS=""

# Process each outdated tool
while IFS= read -r update; do
    TOOL=$(echo "$update" | jq -r '.tool')
    CURRENT=$(echo "$update" | jq -r '.current')
    LATEST=$(echo "$update" | jq -r '.latest')
    FILE=$(echo "$update" | jq -r '.file')

    # `set -e` must not abort the loop on a per-tool failure: one stalled tool
    # should never prevent the remaining valid updates from being applied.
    UPDATE_RC=0
    update_version "$TOOL" "$CURRENT" "$LATEST" "$FILE" || UPDATE_RC=$?

    case "$UPDATE_RC" in
        0)
            SUCCESSFUL_UPDATES=$((SUCCESSFUL_UPDATES + 1))
            UPDATES_APPLIED=true
            ;;
        "$RC_NO_UPDATER_CASE")
            MISSING_CASES=$((MISSING_CASES + 1))
            MISSING_CASE_TOOLS="${MISSING_CASE_TOOLS}${MISSING_CASE_TOOLS:+, }${TOOL}"
            ;;
        "$RC_INVALID_VERSION")
            INVALID_VERSIONS=$((INVALID_VERSIONS + 1))
            INVALID_VERSION_TOOLS="${INVALID_VERSION_TOOLS}${INVALID_VERSION_TOOLS:+, }${TOOL}"
            ;;
        # Catch-all: RC_UPDATE_FAILED (4) and any code a future updaters.sh
        # adds. Deliberately unnamed — anything unrecognized is treated as a
        # real failure rather than silently ignored. Note the two number
        # spaces differ: these are update_version()'s RETURN codes, while the
        # script's own EXIT codes below are 2 and 3. A tool landing here
        # produces exit 3.
        *)
            UPDATE_ERRORS=$((UPDATE_ERRORS + 1))
            ERROR_TOOLS="${ERROR_TOOLS}${ERROR_TOOLS:+, }${TOOL}"
            ;;
    esac
done < <(echo "$OUTDATED" | jq -c '.[]')

# Total failures across all causes — drives the summary and the exit code.
FAILED_UPDATES=$((INVALID_VERSIONS + MISSING_CASES + UPDATE_ERRORS))

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
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Dry run complete - no changes made${NC}"
    else
        echo -e "${YELLOW}No updates applied${NC}"
    fi
fi

# Failure summary lives OUTSIDE the UPDATES_APPLIED branch on purpose. It used
# to sit inside it, so a run where *every* update failed left UPDATES_APPLIED
# false and printed only "No updates applied" — no failure count at all. The
# worst case was the most silent (issue #781).
if [ "$FAILED_UPDATES" -gt 0 ]; then
    echo ""
    if [ "$MISSING_CASES" -gt 0 ]; then
        echo -e "${RED}Updates skipped (no updater case — add one in bin/lib/update-versions/updaters.sh): $MISSING_CASES${NC}" >&2
        echo -e "${RED}  ${MISSING_CASE_TOOLS}${NC}" >&2
        echo -e "${YELLOW}  These tools are pinned at their current versions and will stay there until a case is added.${NC}" >&2
    fi
    if [ "$INVALID_VERSIONS" -gt 0 ]; then
        echo -e "${YELLOW}Updates skipped (invalid version strings): $INVALID_VERSIONS${NC}" >&2
        echo -e "${YELLOW}  ${INVALID_VERSION_TOOLS}${NC}" >&2
    fi
    if [ "$UPDATE_ERRORS" -gt 0 ]; then
        echo -e "${RED}Updates failed (rewrite error): $UPDATE_ERRORS${NC}" >&2
        echo -e "${RED}  ${ERROR_TOOLS}${NC}" >&2
        echo -e "${RED}  A matching case ran but its rewrite failed — the tree may be partially updated.${NC}" >&2
    fi

    # Exit non-zero so an automated caller cannot report success while tools
    # silently stall.
    #
    # Two distinct codes, because the two situations warrant different CI
    # handling:
    #
    #   2 — nothing was rewritten for some tool (no updater case, or a
    #       malformed upstream version). The tree is consistent; the tools just
    #       stalled. auto-patch.yml keeps the updates that DID apply and warns.
    #   3 — a matching case ran and its rewrite FAILED (e.g. pin_action could
    #       not resolve a SHA, or the luggage catalog update failed). The tree
    #       may be half-updated — a Dockerfile ARG bumped while its vendored
    #       catalog entry was not (issue #506) ships a build that cannot
    #       succeed. That must never sail through auto-merge, so it is fatal to
    #       the job rather than a tolerated skip.
    #
    # A dry run exits the same way a real run would. It walks the full updater
    # dispatch (writes are suppressed in the helpers, not by returning early),
    # so it observes the same skip taxonomy — including a missing updater case,
    # which it previously could not reach at all. Exiting 0 there made
    # `just update-versions --dry-run` a false all-clear for exactly the stall
    # #781 exists to catch; matching the real exit code makes it a preflight a
    # caller can gate on (issue #783). It still writes nothing.
    #
    # In practice a dry run cannot reach exit 3: both rewrite-failure sources
    # (pin_action's SHA resolution, update_luggage_catalog's binary probe)
    # short-circuit before doing the work that could fail.
    if [ "$UPDATE_ERRORS" -gt 0 ]; then
        exit 3
    fi
    exit 2
fi
