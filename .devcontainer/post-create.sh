#!/bin/bash
# post-create.sh — Runs ONCE when the devcontainer is first created
# (devcontainer.json `postCreateCommand`). Every-start work lives in
# post-start.sh.
#
# Installs lefthook hooks, checks .env posture, reports recommended tools and
# git config, and warns loudly when the running image disagrees with the
# INCLUDE_* build args in docker-compose.yml (a stale image).
#
# Every check here is ADVISORY and the script must exit 0: VS Code skips
# `postStartCommand` when `postCreateCommand` fails, which would also skip
# setup-git / setup-gh (git identity + SSH auth keys) on first start.
set -euo pipefail

# Get the directory where this script is located
DEVCONTAINER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$DEVCONTAINER_DIR")"

# Colors for output
# shellcheck source=lib/shared/colors.sh
source "$PROJECT_ROOT/lib/shared/colors.sh"

check_tool() {
    local tool=$1
    local install_hint=$2

    if command -v "$tool" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $tool installed"
    else
        echo -e "${YELLOW}⚠${NC}  $tool not found - $install_hint"
    fi
    # Recommended tools are advisory only. NEVER fail: this script runs under
    # `set -euo pipefail`, and a non-zero postCreateCommand makes VS Code skip
    # postStartCommand — so a merely-missing recommended tool (e.g. docker in
    # an image built without INCLUDE_DOCKER) would silently skip setup-git /
    # setup-gh — no git identity, no SSH auth key installed at startup.
    return 0
}

# check_image_drift <compose_file> <features_conf>
#   Compare the INCLUDE_* build args in the compose file against the image's
#   build-time record in enabled-features.conf. Only keys present in BOTH are
#   compared: the conf records a subset of features (the *_DEV flags plus a few
#   support tools), so compose keys it lacks are listed as "not checked" rather
#   than silently counted as matching. Prints a loud warning naming each
#   mismatch and returns 1 on drift; returns 0 when clean or when either file
#   is absent (nothing to compare against).
#
#   The compose parse is line-based: it reads every `INCLUDE_*: true|false`
#   line (quoted or not), not only those under build.args. Fine for this
#   repo's compose, which sets INCLUDE_* only as build args.
#
#   Warn only — never install the missing toolchain. The fix is a rebuild.
check_image_drift() {
    local compose_file=$1
    local features_conf=$2

    if [ ! -f "$features_conf" ]; then
        echo -e "${YELLOW}⚠${NC}  $features_conf not found - skipping image drift check"
        return 0
    fi
    if [ ! -f "$compose_file" ]; then
        echo -e "${YELLOW}⚠${NC}  $compose_file not found - skipping image drift check"
        return 0
    fi

    local key want have
    local -a mismatches=() unchecked=()
    local compared=0
    while read -r key want; do
        have=$(command sed -n "s/^${key}=\\(true\\|false\\)\$/\\1/p" "$features_conf" | command tail -n 1)
        if [ -z "$have" ]; then
            unchecked+=("$key")
            continue
        fi
        compared=$((compared + 1))
        if [ "$want" != "$have" ]; then
            mismatches+=("$key: compose=$want image=$have")
        fi
    done < <(command sed -n -E 's/^[[:space:]]*(INCLUDE_[A-Z0-9_]+):[[:space:]]*["'\'']?(true|false)["'\'']?[[:space:]]*(#.*)?$/\1 \2/p' "$compose_file")

    if [ ${#unchecked[@]} -gt 0 ]; then
        echo "  Not checked (image does not record): ${unchecked[*]}"
    fi

    if [ "$compared" -eq 0 ]; then
        echo -e "${YELLOW}⚠${NC}  No INCLUDE_* flag recorded by both files - drift not verified"
        return 0
    fi

    if [ ${#mismatches[@]} -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Image matches docker-compose.yml on $compared recorded INCLUDE_* flag(s)"
        return 0
    fi

    echo -e "${RED}✗ IMAGE IS STALE — REBUILD${NC}"
    echo "  The running image was built with different INCLUDE_* args than"
    echo "  .devcontainer/docker-compose.yml now declares:"
    local m
    for m in "${mismatches[@]}"; do
        echo -e "    ${RED}✗${NC} $m"
    done
    echo "  Rebuild the container (VS Code: \"Dev Containers: Rebuild Container\";"
    echo "  Zed: see docs/troubleshooting/zed-devcontainer.md#rebuilding-the-container)."
    return 1
}

main() {
    echo -e "${BLUE}=== Container Build System - Development Environment Setup ===${NC}"
    echo ""

    cd "$PROJECT_ROOT"

    # 1. Install lefthook git hooks
    echo -e "${BLUE}[1/5] Installing lefthook git hooks...${NC}"

    if command -v lefthook &>/dev/null; then
        if lefthook install >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} lefthook hooks installed (pre-commit + pre-push)"
        else
            echo -e "${YELLOW}⚠${NC}  Failed to install lefthook hooks"
        fi
    else
        echo -e "${YELLOW}⚠${NC}  lefthook not found"
        echo "  lefthook ships with INCLUDE_DEV_TOOLS=true."
        echo "  Rebuild the container or install manually, then re-run this script."
    fi

    # 2. Verify .env is not committed
    echo ""
    echo -e "${BLUE}[2/5] Checking .env file...${NC}"
    if [ -f .env ]; then
        # Check if it contains any real tokens
        if command grep -qE '(ops_eyJ|github_pat_[A-Z]|ghp_[A-Z]|gho_[A-Z])' .env; then
            echo -e "${YELLOW}⚠${NC}  .env contains what appear to be real credentials"
            echo "  Please ensure these are invalidated before sharing this repository"
        else
            echo -e "${GREEN}✓${NC} .env exists and appears sanitized"
        fi
    else
        echo -e "${YELLOW}⚠${NC}  .env does not exist (this is fine)"
        echo "  Copy from .env.example if needed: cp .env.example .env"
    fi

    # Verify .env is ignored. git check-ignore honors any pattern form
    # (`.env`, `**/.env`, …) where an exact-line grep would not. Outside a
    # work tree it exits 128, which must not read as "not ignored".
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠${NC}  Not inside a git work tree - skipping .gitignore check"
    elif git check-ignore -q .env 2>/dev/null; then
        echo -e "${GREEN}✓${NC} .env is ignored by .gitignore"
    else
        echo -e "${RED}✗${NC} .env is NOT ignored - adding it to .gitignore now..."
        # Start on a fresh line if .gitignore lacks a trailing newline, and
        # never fail the script on a write error (see the exit-0 note above).
        if [ -s .gitignore ] && [ -n "$(command tail -c 1 .gitignore)" ]; then
            echo >>.gitignore || true
        fi
        echo ".env" >>.gitignore ||
            echo -e "${YELLOW}⚠${NC}  Could not write .gitignore - add .env manually"
    fi

    # 3. Check recommended tools
    echo ""
    echo -e "${BLUE}[3/5] Checking recommended development tools...${NC}"

    check_tool "shellcheck" "apt-get install shellcheck (or brew install shellcheck)"
    check_tool "docker" "https://docs.docker.com/get-docker/"
    check_tool "gh" "https://cli.github.com/"
    check_tool "jq" "apt-get install jq (or brew install jq)"
    check_tool "git-cliff" "cargo install git-cliff (optional, for changelogs)"
    check_tool "lefthook" "included in dev-tools feature"
    check_tool "biome" "included in dev-tools feature"

    # 4. Check the image matches docker-compose.yml
    echo ""
    echo -e "${BLUE}[4/5] Checking image against docker-compose.yml...${NC}"
    check_image_drift "$DEVCONTAINER_DIR/docker-compose.yml" \
        "${ENABLED_FEATURES_CONF:-/etc/container/config/enabled-features.conf}" || true

    # 5. Check git configuration
    echo ""
    echo -e "${BLUE}[5/5] Checking git configuration...${NC}"
    if git config user.name >/dev/null && git config user.email >/dev/null; then
        echo -e "${GREEN}✓${NC} Git user.name and user.email are configured"
    else
        echo -e "${YELLOW}⚠${NC}  Git user.name or user.email not configured yet"
        echo "  On first create this is expected: post-start.sh runs setup-git next,"
        echo "  which sets identity from secrets. Otherwise set it manually:"
        echo "  Set with: git config --global user.name \"Your Name\""
        echo "  Set with: git config --global user.email \"your@email.com\""
    fi

    # Summary
    echo ""
    echo -e "${GREEN}=== Setup Complete ===${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Run tests: just test"
    echo "  2. Build a container: docker build -t test:minimal --build-arg PROJECT_NAME=test --build-arg PROJECT_PATH=. ."
    echo "  3. See docs/README.md for more information"
    echo ""
    echo "Git hooks are now active (via lefthook):"
    echo ""
    echo "Pre-commit hook (runs on: git commit):"
    echo "  - Trailing whitespace and EOF fixes"
    echo "  - YAML/JSON validation"
    echo "  - Shellcheck on shell scripts"
    echo "  - Markdown linting + formatting (rumdl)"
    echo "  - YAML/JSON formatting (dprint)"
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
}

# Source guard: tests source this file to exercise check_image_drift directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
