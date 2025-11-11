#!/bin/bash
# Setup development environment for container build system
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Container Build System - Development Environment Setup ===${NC}"
echo ""

# Get the directory where this script is located
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$BIN_DIR")"

cd "$PROJECT_ROOT"

# 1. Configure git hooks
echo -e "${BLUE}[1/3] Configuring git hooks...${NC}"
if git config core.hooksPath .githooks; then
    echo -e "${GREEN}✓${NC} Git hooks enabled (.githooks)"
    echo "  - Shellcheck validation on commits"
    echo "  - Credential leak prevention"
else
    echo -e "${RED}✗${NC} Failed to configure git hooks"
    exit 1
fi

# 2. Verify .env is not committed
echo ""
echo -e "${BLUE}[2/3] Checking .env file...${NC}"
if [ -f .env ]; then
    # Check if it contains any real tokens
    if grep -qE '(ops_eyJ|github_pat_[A-Z]|ghp_[A-Z]|gho_[A-Z])' .env; then
        echo -e "${YELLOW}⚠${NC}  .env contains what appear to be real credentials"
        echo "  Please ensure these are invalidated before sharing this repository"
    else
        echo -e "${GREEN}✓${NC} .env exists and appears sanitized"
    fi
else
    echo -e "${YELLOW}⚠${NC}  .env does not exist (this is fine)"
    echo "  Copy from .env.example if needed: cp .env.example .env"
fi

# Verify .env is in .gitignore
if grep -q "^\.env$" .gitignore; then
    echo -e "${GREEN}✓${NC} .env is in .gitignore"
else
    echo -e "${RED}✗${NC} .env is NOT in .gitignore - adding it now..."
    echo ".env" >> .gitignore
fi

# 3. Check recommended tools
echo ""
echo -e "${BLUE}[3/3] Checking recommended development tools...${NC}"

check_tool() {
    local tool=$1
    local install_hint=$2

    if command -v "$tool" &> /dev/null; then
        echo -e "${GREEN}✓${NC} $tool installed"
        return 0
    else
        echo -e "${YELLOW}⚠${NC}  $tool not found - $install_hint"
        return 1
    fi
}

check_tool "shellcheck" "apt-get install shellcheck (or brew install shellcheck)"
check_tool "docker" "https://docs.docker.com/get-docker/"
check_tool "gh" "https://cli.github.com/"
check_tool "git-cliff" "cargo install git-cliff (optional, for changelogs)"

# Summary
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Run tests: ./tests/run_all.sh"
echo "  2. Build a container: docker build -t test:minimal --build-arg PROJECT_NAME=test --build-arg PROJECT_PATH=. ."
echo "  3. See docs/README.md for more information"
echo ""
echo "Pre-commit hooks are now active. They will:"
echo "  - Run shellcheck on shell scripts"
echo "  - Prevent .env file commits"
echo "  - Detect common credential patterns"
echo ""
echo "To skip hooks temporarily: git commit --no-verify"
