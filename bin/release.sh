#!/bin/bash
# Release management script for Container Build System
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Release automation flags
AUTO_COMMIT=false
AUTO_TAG=false
AUTO_PUSH=false
AUTO_GITHUB_RELEASE=false

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
    local os_type
    os_type=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch
    arch=$(uname -m)
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
    local temp_dir
    temp_dir=$(mktemp -d)

    echo "Downloading git-cliff from $download_url..."
    if command curl -sL "$download_url" | tar xz -C "$temp_dir"; then
        sudo command mv "$temp_dir/git-cliff-${version}/git-cliff" /usr/local/bin/
        sudo chmod +x /usr/local/bin/git-cliff
        command rm -rf "$temp_dir"
        echo -e "${GREEN}✓${NC} git-cliff installed successfully"
        return 0
    else
        command rm -rf "$temp_dir"
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
        # Remove trailing blank lines to pass markdown lint (MD012)
        # This creates a temp file, removes trailing newlines, then moves it back
        local tmp_file
        tmp_file=$(mktemp)
        # Remove trailing blank lines while preserving final newline
        sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' CHANGELOG.md > "$tmp_file" && mv "$tmp_file" CHANGELOG.md
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

# Check if we're in a git repository
if [ -d .git ]; then
    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo -e "${YELLOW}Note: You have uncommitted changes${NC}"
        echo ""
    fi

    # Auto-commit if requested
    if [ "$AUTO_COMMIT" = "true" ]; then
        echo ""
        echo -e "${BLUE}Auto-committing changes...${NC}"
        git add -A
        git commit -m "chore(release): Release version $NEW_VERSION"
        echo -e "${GREEN}✓${NC} Changes committed"
    fi

    # Reorder: push first, then tag (prevents tagging commits that fail validation)
    if [ "$AUTO_PUSH" = "true" ]; then
        echo ""
        echo -e "${BLUE}Pushing changes to remote...${NC}"

        # Get current branch
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

        # Push branch first (this runs pre-push validation hook)
        if ! git push origin "$CURRENT_BRANCH"; then
            echo -e "${RED}✗ Failed to push branch${NC}"
            echo "Pre-push validation failed. Fix the issues and try again."
            exit 1
        fi
        echo -e "${GREEN}✓${NC} Pushed branch: $CURRENT_BRANCH"

        # Only create and push tag if branch push succeeded
        if [ "$AUTO_TAG" = "true" ]; then
            echo ""
            echo -e "${BLUE}Creating git tag v$NEW_VERSION...${NC}"
            git tag -a "v$NEW_VERSION" -m "Release version $NEW_VERSION"
            echo -e "${GREEN}✓${NC} Tag created"

            if ! git push origin "v$NEW_VERSION"; then
                echo -e "${RED}✗ Failed to push tag${NC}"
                exit 1
            fi
            echo -e "${GREEN}✓${NC} Pushed tag: v$NEW_VERSION"
        fi
    else
        # Not auto-pushing - create tag locally if requested
        if [ "$AUTO_TAG" = "true" ]; then
            echo ""
            echo -e "${BLUE}Creating git tag v$NEW_VERSION...${NC}"
            git tag -a "v$NEW_VERSION" -m "Release version $NEW_VERSION"
            echo -e "${GREEN}✓${NC} Tag created"
        fi
    fi

    # Auto-create GitHub release if requested
    if [ "$AUTO_GITHUB_RELEASE" = "true" ]; then
        echo ""
        echo -e "${BLUE}Creating GitHub release...${NC}"

        # Check if gh is installed
        if ! command -v gh >/dev/null 2>&1; then
            echo -e "${YELLOW}Warning: gh CLI not found, skipping GitHub release${NC}"
            echo "Install gh CLI: https://cli.github.com/"
        else
            # Switch to config auth if GITHUB_TOKEN is set
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                unset GITHUB_TOKEN
                gh auth switch 2>/dev/null || true
            fi

            # Generate release notes from CHANGELOG
            RELEASE_NOTES=$(./bin/generate-release-notes.sh "$NEW_VERSION" 2>/dev/null || echo "See [CHANGELOG.md](https://github.com/joshjhall/containers/blob/v$NEW_VERSION/CHANGELOG.md) for details.")

            # Create release
            if gh release create "v$NEW_VERSION" \
                --title "Release v$NEW_VERSION" \
                --notes "$RELEASE_NOTES"; then
                echo -e "${GREEN}✓${NC} GitHub release created: https://github.com/joshjhall/containers/releases/tag/v$NEW_VERSION"
            else
                echo -e "${YELLOW}Warning: Failed to create GitHub release${NC}"
                echo "You can create it manually at: https://github.com/joshjhall/containers/releases/new?tag=v$NEW_VERSION"
            fi
        fi
    fi

    # Show next steps if not fully automated
    if [ "$AUTO_COMMIT" = "false" ] || [ "$AUTO_TAG" = "false" ] || [ "$AUTO_PUSH" = "false" ]; then
        echo ""
        echo "To complete the release, run:"
        if [ "$AUTO_COMMIT" = "false" ]; then
            echo -e "  ${BLUE}git add -A${NC}"
            echo -e "  ${BLUE}git commit -m \"chore(release): Release version $NEW_VERSION\"${NC}"
        fi
        if [ "$AUTO_TAG" = "false" ]; then
            echo -e "  ${BLUE}git tag -a v$NEW_VERSION -m \"Release version $NEW_VERSION\"${NC}"
        fi
        if [ "$AUTO_PUSH" = "false" ]; then
            CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
            echo -e "  ${BLUE}git push origin $CURRENT_BRANCH${NC}"
            echo -e "  ${BLUE}git push origin v$NEW_VERSION${NC}"
        fi
        if [ "$AUTO_GITHUB_RELEASE" = "false" ]; then
            echo ""
            echo "Or use automation flags:"
            echo -e "  ${BLUE}$0 --full-auto $*${NC}  # Fully automated release"
        fi
        echo ""
        echo "The tag push will trigger GitHub Actions to:"
        echo "  - Build all container variants"
        echo "  - Push images to ghcr.io/joshjhall/containers"
    fi
else
    echo -e "${YELLOW}Not a git repository - manual commit required${NC}"
fi