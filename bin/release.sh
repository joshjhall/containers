#!/bin/bash
# Release management script for Container Build System
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script is located
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$BIN_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

# Function to display usage
usage() {
    echo "Usage: $0 [--force] [major|minor|patch|VERSION]"
    echo ""
    echo "Examples:"
    echo "  $0 patch         # Bump patch version (1.0.0 -> 1.0.1)"
    echo "  $0 minor         # Bump minor version (1.0.0 -> 1.1.0)"
    echo "  $0 major         # Bump major version (1.0.0 -> 2.0.0)"
    echo "  $0 1.2.3         # Set specific version"
    echo "  $0 --force 1.2.3 # Force set version (even if same)"
    echo ""
    echo "Current version: $(cat VERSION)"
    exit 1
}

# Function to validate version format
validate_version() {
    if ! echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo -e "${RED}Error: Invalid version format. Expected: X.Y.Z${NC}"
        exit 1
    fi
}

# Function to bump version
bump_version() {
    local current_version="$1"
    local bump_type="$2"
    
    IFS='.' read -r major minor patch <<< "$current_version"
    
    case "$bump_type" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            echo -e "${RED}Error: Invalid bump type${NC}"
            exit 1
            ;;
    esac
    
    echo "${major}.${minor}.${patch}"
}

# Check if VERSION file exists
if [ ! -f VERSION ]; then
    echo -e "${RED}Error: VERSION file not found${NC}"
    exit 1
fi

# Get current version
CURRENT_VERSION=$(cat VERSION)
validate_version "$CURRENT_VERSION"

# Parse arguments
FORCE_UPDATE=false
if [ $# -eq 0 ]; then
    usage
fi

# Check for --force flag
if [ "$1" = "--force" ]; then
    FORCE_UPDATE=true
    shift
    if [ $# -eq 0 ]; then
        usage
    fi
fi

# Determine new version
if [[ "$1" =~ ^(major|minor|patch)$ ]]; then
    NEW_VERSION=$(bump_version "$CURRENT_VERSION" "$1")
else
    NEW_VERSION="$1"
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

# Confirm with user
echo ""
read -p "Continue with release? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Release cancelled"
    exit 1
fi

# Update VERSION file
echo "$NEW_VERSION" > VERSION
echo -e "${GREEN}✓${NC} Updated VERSION file"

# Update Dockerfile version
sed -i.bak "s/# Version: .*/# Version: $NEW_VERSION/" Dockerfile && rm Dockerfile.bak
echo -e "${GREEN}✓${NC} Updated Dockerfile version"

# Update test framework version if it exists
if [ -f tests/framework.sh ]; then
    sed -i.bak "s/readonly TEST_FRAMEWORK_VERSION=.*/readonly TEST_FRAMEWORK_VERSION=\"$NEW_VERSION\"/" tests/framework.sh && rm tests/framework.sh.bak
    sed -i.bak "s/# Version: .*/# Version: $NEW_VERSION/" tests/framework.sh && rm tests/framework.sh.bak
    echo -e "${GREEN}✓${NC} Updated test framework version"
fi

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
    echo "Please commit your changes before creating the release tag"
    echo ""
    echo "Suggested commands:"
    echo "  git add -A"
    echo "  git commit -m \"Release version $NEW_VERSION\""
    echo "  git tag -a v$NEW_VERSION -m \"Release version $NEW_VERSION\""
    echo "  git push origin main"
    echo "  git push origin v$NEW_VERSION"
else
    echo ""
    echo -e "${GREEN}Version updated successfully!${NC}"
    echo ""
    echo "To complete the release:"
    echo "  1. Update CHANGELOG.md with release notes"
    echo "  2. Commit changes: git commit -am \"Release version $NEW_VERSION\""
    echo "  3. Create tag: git tag -a v$NEW_VERSION -m \"Release version $NEW_VERSION\""
    echo "  4. Push changes: git push origin main"
    echo "  5. Push tag: git push origin v$NEW_VERSION"
fi

echo ""
echo "For GitLab CI integration (future):"
echo "  - Tags will trigger automated builds"
echo "  - Images will be pushed to GitLab Container Registry"
echo "  - Format: registry.gitlab.com/yourorg/containers:v$NEW_VERSION"