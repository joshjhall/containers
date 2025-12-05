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

# 1. Install pre-commit hooks
echo -e "${BLUE}[1/4] Installing pre-commit hooks...${NC}"

if command -v pre-commit &> /dev/null; then
    # Install commit and push hooks
    if pre-commit install --install-hooks > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} pre-commit hooks installed"
    else
        echo -e "${YELLOW}⚠${NC}  Failed to install pre-commit hooks"
    fi

    if pre-commit install --hook-type pre-push > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} pre-push hooks installed"
    else
        echo -e "${YELLOW}⚠${NC}  Failed to install pre-push hooks"
    fi
else
    echo -e "${YELLOW}⚠${NC}  pre-commit not found"
    echo "  Install with: pip install pre-commit"
    echo "  Then re-run this script"
fi

# 2. Verify .env is not committed
echo ""
echo -e "${BLUE}[2/4] Checking .env file...${NC}"
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
echo -e "${BLUE}[3/4] Checking recommended development tools...${NC}"

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
check_tool "jq" "apt-get install jq (or brew install jq)"
check_tool "git-cliff" "cargo install git-cliff (optional, for changelogs)"
check_tool "pre-commit" "pip install pre-commit"
check_tool "biome" "included in dev-tools feature"

# 4. Check git configuration
echo ""
echo -e "${BLUE}[4/4] Checking git configuration...${NC}"
if git config user.name > /dev/null && git config user.email > /dev/null; then
    echo -e "${GREEN}✓${NC} Git user.name and user.email are configured"
else
    echo -e "${YELLOW}⚠${NC}  Git user.name or user.email not configured"
    echo "  Set with: git config --global user.name \"Your Name\""
    echo "  Set with: git config --global user.email \"your@email.com\""
fi

# Summary
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Run tests: ./tests/run_all.sh"
echo "  2. Build a container: docker build -t test:minimal --build-arg PROJECT_NAME=test --build-arg PROJECT_PATH=. ."
echo "  3. See docs/README.md for more information"
echo ""
echo "Git hooks are now active (via pre-commit framework):"
echo ""
echo "Pre-commit hook (runs on: git commit):"
echo "  - Trailing whitespace and EOF fixes"
echo "  - YAML/JSON validation"
echo "  - Shellcheck on shell scripts"
echo "  - Markdown formatting (mdformat)"
echo "  - Markdown linting (pymarkdown)"
echo "  - JSON linting (biome)"
echo "  - Secret detection (gitleaks)"
echo "  - Credential pattern detection"
echo "  - Shell script permission fixes"
echo "  - Skip with: git commit --no-verify"
echo ""
echo "Pre-push hook (runs on: git push):"
echo "  - Unit tests"
echo "  - Docker Compose validation"
echo "  - Skip with: git push --no-verify"
echo ""
