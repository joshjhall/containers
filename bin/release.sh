#!/bin/bash
# Release management script for Container Build System
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Release automation flags (used by sourced git-automation.sh)
export AUTO_COMMIT=false
export AUTO_TAG=false
export AUTO_PUSH=false
export AUTO_GITHUB_RELEASE=false

# Get the directory where this script is located
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$BIN_DIR")"

# Source shared utilities
source "${BIN_DIR}/lib/version-utils.sh"
source "${BIN_DIR}/lib/release/git-cliff.sh"
source "${BIN_DIR}/lib/release/git-automation.sh"

# Change to project root
cd "$PROJECT_ROOT"

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS] [major|minor|patch|VERSION]"
    echo ""
    echo "Options:"
    echo "  --force                 Force version update even if same"
    echo "  --skip-changelog        Skip CHANGELOG.md generation"
    echo "  --non-interactive       Skip confirmation prompts (for CI/CD)"
    echo "  --auto-commit           Automatically commit changes"
    echo "  --auto-tag              Automatically create git tag"
    echo "  --auto-push             Automatically push to remote"
    echo "  --auto-github-release   Automatically create GitHub release"
    echo "  --full-auto             Enable all auto flags (commit, tag, push, release)"
    echo ""
    echo "Examples:"
    echo "  $0 patch                      # Bump patch version (1.0.0 -> 1.0.1)"
    echo "  $0 minor                      # Bump minor version (1.0.0 -> 1.1.0)"
    echo "  $0 major                      # Bump major version (1.0.0 -> 2.0.0)"
    echo "  $0 1.2.3                      # Set specific version"
    echo "  $0 --force 1.2.3              # Force set version (even if same)"
    echo "  $0 --non-interactive patch    # Run without prompts (CI/CD)"
    echo "  $0 --full-auto minor          # Complete automated release"
    echo ""
    echo "Current version: $(command cat VERSION)"
    exit 1
}

# Function to validate version format (semver-strict for release)
validate_version() {
    if ! echo "$1" | command grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo -e "${RED}Error: Invalid version format. Expected: X.Y.Z${NC}"
        exit 1
    fi
}

# bump_version() is sourced from bin/lib/version-utils.sh

# Check if VERSION file exists
if [ ! -f VERSION ]; then
    echo -e "${RED}Error: VERSION file not found${NC}"
    exit 1
fi

# Get current version
CURRENT_VERSION=$(command cat VERSION)
validate_version "$CURRENT_VERSION"

# Parse arguments
FORCE_UPDATE=false
SKIP_CHANGELOG=false
NON_INTERACTIVE=false
VERSION_ARG=""

if [ $# -eq 0 ]; then
    usage
fi

# Parse all arguments (allows flags in any position)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_UPDATE=true
            shift
            ;;
        --skip-changelog)
            SKIP_CHANGELOG=true
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --auto-commit)
            AUTO_COMMIT=true
            shift
            ;;
        --auto-tag)
            AUTO_TAG=true
            shift
            ;;
        --auto-push)
            AUTO_PUSH=true
            shift
            ;;
        --auto-github-release)
            AUTO_GITHUB_RELEASE=true
            shift
            ;;
        --full-auto)
            AUTO_COMMIT=true
            AUTO_TAG=true
            AUTO_PUSH=true
            AUTO_GITHUB_RELEASE=true
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            # This should be the version argument
            if [ -z "$VERSION_ARG" ]; then
                VERSION_ARG="$1"
                shift
            else
                echo -e "${RED}Error: Multiple version arguments provided: '$VERSION_ARG' and '$1'${NC}"
                usage
            fi
            ;;
    esac
done

# Check we have a version argument
if [ -z "$VERSION_ARG" ]; then
    usage
fi

# Determine new version
if [[ "$VERSION_ARG" =~ ^(major|minor|patch)$ ]]; then
    NEW_VERSION=$(bump_version "$CURRENT_VERSION" "$VERSION_ARG")
else
    NEW_VERSION="$VERSION_ARG"
    validate_version "$NEW_VERSION"
fi

# Display version info
echo -e "${BLUE}Current version:${NC} $CURRENT_VERSION"
echo -e "${BLUE}New version:${NC}     $NEW_VERSION"

# Check if version is the same and not forcing
if [ "$CURRENT_VERSION" = "$NEW_VERSION" ] && [ "$FORCE_UPDATE" = "false" ]; then
    echo -e "${YELLOW}Version is already $NEW_VERSION. Use --force to update anyway.${NC}"
    exit 1
fi

# ensure_git_cliff() is sourced from bin/lib/release/git-cliff.sh

# Function to generate changelog
generate_changelog() {
    local new_version="$1"

    if [ "$SKIP_CHANGELOG" = "true" ]; then
        echo -e "${YELLOW}Skipping CHANGELOG generation${NC}"
        return 0
    fi

    echo -e "${BLUE}Generating CHANGELOG.md...${NC}"

    # Ensure git-cliff is available
    if ! ensure_git_cliff; then
        echo -e "${YELLOW}Warning: Could not install git-cliff, skipping CHANGELOG generation${NC}"
        echo "You can manually update CHANGELOG.md or install git-cliff and run:"
        echo "  git-cliff -o CHANGELOG.md --tag v$new_version"
        return 1
    fi

    # Generate changelog
    if git-cliff -o CHANGELOG.md --tag "v$new_version"; then
        # Remove trailing blank lines to pass markdown lint (MD012)
        # This creates a temp file, removes trailing newlines, then moves it back
        local tmp_file
        tmp_file=$(mktemp)
        # Remove trailing blank lines while preserving final newline
        command sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' CHANGELOG.md > "$tmp_file" && mv "$tmp_file" CHANGELOG.md
        echo -e "${GREEN}✓${NC} Generated CHANGELOG.md"
        return 0
    else
        echo -e "${YELLOW}Warning: Failed to generate CHANGELOG.md${NC}"
        return 1
    fi
}

# Confirm with user
if [ "$NON_INTERACTIVE" = "false" ]; then
    echo ""
    read -p "Continue with release? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Release cancelled${NC}"
        echo ""
        echo "To automate this process, you can use:"
        echo -e "  ${BLUE}echo 'y' | $0 $*${NC}"
        echo -e "  ${BLUE}yes | $0 $*${NC}"
        echo ""
        echo "Or use non-interactive mode:"
        echo -e "  ${BLUE}$0 --non-interactive $*${NC}"
        exit 1
    fi
fi

# Update VERSION file
echo "$NEW_VERSION" > VERSION
echo -e "${GREEN}✓${NC} Updated VERSION file"

# Update Dockerfile version
command sed -i.bak "s/# Version: .*/# Version: $NEW_VERSION/" Dockerfile && command rm Dockerfile.bak
echo -e "${GREEN}✓${NC} Updated Dockerfile version"

# Update test framework version if it exists
if [ -f tests/framework.sh ]; then
    command sed -i.bak "s/readonly TEST_FRAMEWORK_VERSION=.*/readonly TEST_FRAMEWORK_VERSION=\"$NEW_VERSION\"/" tests/framework.sh && command rm tests/framework.sh.bak
    command sed -i.bak "s/# Version: .*/# Version: $NEW_VERSION/" tests/framework.sh && command rm tests/framework.sh.bak
    echo -e "${GREEN}✓${NC} Updated test framework version"
fi

# Generate CHANGELOG
echo ""
generate_changelog "$NEW_VERSION"

# Display completion message
echo ""
echo -e "${GREEN}✓ Release $NEW_VERSION prepared successfully!${NC}"
echo ""
echo "Updated files:"
echo "  - VERSION"
echo "  - Dockerfile"
echo "  - tests/framework.sh"
if [ "$SKIP_CHANGELOG" = "false" ]; then
    echo "  - CHANGELOG.md"
fi
echo ""

# Perform git operations (commit, tag, push, GitHub release)
perform_git_automation "$NEW_VERSION"
