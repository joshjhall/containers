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
echo -e "${BLUE}[1/4] Configuring git hooks...${NC}"
if git config core.hooksPath .githooks; then
    echo -e "${GREEN}✓${NC} Git hooks enabled (.githooks)"
    echo "  - Shellcheck validation on commits"
    echo "  - Credential leak prevention"
else
    echo -e "${RED}✗${NC} Failed to configure git hooks"
    exit 1
fi

# Verify hook files exist and are executable
for hook in pre-commit pre-push; do
    hook_file=".githooks/$hook"
    if [ -f "$hook_file" ]; then
        if [ -x "$hook_file" ]; then
            echo -e "${GREEN}✓${NC} $hook hook is executable"
        else
            echo -e "${YELLOW}⚠${NC}  $hook hook exists but is not executable - fixing..."
            chmod +x "$hook_file"
            echo -e "${GREEN}✓${NC} Made $hook hook executable"
        fi
    else
        echo -e "${YELLOW}⚠${NC}  $hook hook not found at $hook_file"
    fi
done

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
echo "Git hooks are now active:"
echo ""
echo "Pre-commit hook (runs on: git commit):"
echo "  - Run shellcheck on staged files"
echo "  - Prevent .env file commits"
echo "  - Detect common credential patterns"
echo "  - Skip with: git commit --no-verify"
echo ""
echo "Pre-push hook (runs on: git push):"
echo "  - Run shellcheck on all shell scripts"
echo "  - Run unit tests (fast, no Docker required)"
echo "  - Skip with: git push --no-verify"
