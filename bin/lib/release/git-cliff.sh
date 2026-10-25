#!/bin/bash
# git-cliff installation helper for release.sh
#
# Description:
#   Ensures git-cliff is available for CHANGELOG generation.
#   Tries cargo install first, then falls back to pre-built binary.
#
# Usage:
#   source "${BIN_DIR}/lib/release/git-cliff.sh"
#   ensure_git_cliff || echo "git-cliff not available"

# Function to install git-cliff if not available
ensure_git_cliff() {
    if command -v git-cliff &>/dev/null; then
        return 0
    fi

    echo -e "${BLUE}git-cliff not found, installing...${NC}"

    # Try to install via cargo if available
    if command -v cargo &>/dev/null; then
        cargo install git-cliff
        return $?
    fi

    # Try to download pre-built binary
    local os_type
    os_type=$(uname -s | command tr '[:upper:]' '[:lower:]')
    local arch
    arch=$(uname -m)
    local version="2.8.0"

    # Map architecture
    case "$arch" in
        x86_64) arch="x86_64" ;;
        aarch64 | arm64) arch="aarch64" ;;
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
    if command curl -sfL "$download_url" | tar xz -C "$temp_dir"; then
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

# run_git_cliff_changelog <version> <project-root> - regenerate CHANGELOG.md
#
# --workdir is mandatory: git-cliff 2.8.0 run from a linked worktree (where
# .git is a file) resolves the main checkout instead, treats the worktree
# path as an include filter, matches no commits, and writes a header-only
# CHANGELOG — every past release erased while the caller printed success.
# The output is also checked for at least one release section before it
# replaces CHANGELOG.md, so any other empty generation fails loudly instead.
run_git_cliff_changelog() {
    local new_version="$1" root="$2" tmp
    tmp="$(command mktemp)" || return 1
    if ! git-cliff --workdir "$root" -o "$tmp" --tag "v$new_version"; then
        command rm -f "$tmp"
        return 1
    fi
    if ! command grep -q '^## ' "$tmp"; then
        echo -e "${RED}git-cliff produced no release sections; CHANGELOG.md left unchanged${NC}" >&2
        command rm -f "$tmp"
        return 1
    fi
    command cat "$tmp" >"$root/CHANGELOG.md"
    command rm -f "$tmp"
}
