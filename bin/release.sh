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
    echo "Usage: $0 [OPTIONS] [major|minor|patch|VERSION]"
    echo ""
    echo "Options:"
    echo "  --force              Force version update even if same"
    echo "  --skip-changelog     Skip CHANGELOG.md generation"
    echo "  --non-interactive    Skip confirmation prompts (for CI/CD)"
    echo ""
    echo "Examples:"
    echo "  $0 patch                    # Bump patch version (1.0.0 -> 1.0.1)"
    echo "  $0 minor                    # Bump minor version (1.0.0 -> 1.1.0)"
    echo "  $0 major                    # Bump major version (1.0.0 -> 2.0.0)"
    echo "  $0 1.2.3                    # Set specific version"
    echo "  $0 --force 1.2.3            # Force set version (even if same)"
    echo "  $0 --non-interactive patch  # Run without prompts (CI/CD)"
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
SKIP_CHANGELOG=false
NON_INTERACTIVE=false

if [ $# -eq 0 ]; then
    usage
fi

# Parse options
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
        -h|--help)
            usage
            ;;
        *)
            # This should be the version argument
            break
            ;;
    esac
done

# Check we have a version argument
if [ $# -eq 0 ]; then
    usage
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

# Function to install git-cliff if not available
ensure_git_cliff() {
    if command -v git-cliff &> /dev/null; then
        return 0
    fi

    echo -e "${BLUE}git-cliff not found, installing...${NC}"

    # Try to install via cargo if available
    if command -v cargo &> /dev/null; then
        cargo install git-cliff
        return $?
    fi

    # Try to download pre-built binary
    local os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    local version="2.8.0"

    # Map architecture
    case "$arch" in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *)
            echo -e "${RED}Unsupported architecture: $arch${NC}"
            return 1
            ;;
    esac

    # Map OS
    case "$os_type" in
        linux) os_type="unknown-linux-gnu" ;;
        darwin) os_type="apple-darwin" ;;
        *)
            echo -e "${RED}Unsupported OS: $os_type${NC}"
            return 1
            ;;
    esac

    local download_url="https://github.com/orhun/git-cliff/releases/download/v${version}/git-cliff-${version}-${arch}-${os_type}.tar.gz"
    local temp_dir=$(mktemp -d)

    echo "Downloading git-cliff from $download_url..."
    if curl -sL "$download_url" | tar xz -C "$temp_dir"; then
        sudo mv "$temp_dir/git-cliff-${version}/git-cliff" /usr/local/bin/
        sudo chmod +x /usr/local/bin/git-cliff
        rm -rf "$temp_dir"
        echo -e "${GREEN}✓${NC} git-cliff installed successfully"
        return 0
    else
        rm -rf "$temp_dir"
        echo -e "${RED}Failed to install git-cliff${NC}"
        return 1
    fi
}

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
sed -i.bak "s/# Version: .*/# Version: $NEW_VERSION/" Dockerfile && rm Dockerfile.bak
echo -e "${GREEN}✓${NC} Updated Dockerfile version"

# Update test framework version if it exists
if [ -f tests/framework.sh ]; then
    sed -i.bak "s/readonly TEST_FRAMEWORK_VERSION=.*/readonly TEST_FRAMEWORK_VERSION=\"$NEW_VERSION\"/" tests/framework.sh && rm tests/framework.sh.bak
    sed -i.bak "s/# Version: .*/# Version: $NEW_VERSION/" tests/framework.sh && rm tests/framework.sh.bak
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

# Check if we're in a git repository
if [ -d .git ]; then
    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo -e "${YELLOW}Note: You have uncommitted changes${NC}"
        echo ""
    fi

    echo "To complete the release, run:"
    echo -e "  ${BLUE}git add -A${NC}"
    echo -e "  ${BLUE}git commit -m \"chore(release): Release version $NEW_VERSION\"${NC}"
    echo -e "  ${BLUE}git tag -a v$NEW_VERSION -m \"Release version $NEW_VERSION\"${NC}"
    echo -e "  ${BLUE}git push origin main${NC}"
    echo -e "  ${BLUE}git push origin v$NEW_VERSION${NC}"
    echo ""
    echo "The tag push will trigger GitHub Actions to:"
    echo "  - Build all container variants"
    echo "  - Push images to ghcr.io/joshjhall/containers"
    echo "  - Create GitHub release with release notes"
else
    echo -e "${YELLOW}Not a git repository - manual commit required${NC}"
fi