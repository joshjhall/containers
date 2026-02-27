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
