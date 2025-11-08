#!/bin/bash
# Dev Tools Checksum Updater
#
# Description:
#   Automatically updates SHA256 checksums for development tools in lib/features/dev-tools.sh
#
# Usage:
#   ./bin/lib/update-versions/dev-tools-checksums.sh [LAZYGIT_VER] [DELTA_VER] [ACT_VER] [GITCLIFF_VER]
#
# Arguments:
#   LAZYGIT_VER  - New lazygit version (e.g., "0.56.0")
#   DELTA_VER    - New delta version (e.g., "0.18.2")
#   ACT_VER      - New act version (e.g., "0.2.82")
#   GITCLIFF_VER - New git-cliff version (e.g., "2.8.0")
#
# Example:
#   ./bin/lib/update-versions/dev-tools-checksums.sh 0.56.0 0.18.2 0.2.82 2.8.0

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
source "${SCRIPT_DIR}/../version-utils.sh"
source "${SCRIPT_DIR}/helpers.sh"

# ============================================================================
# Configuration
# ============================================================================

FEATURE_SCRIPT="lib/features/dev-tools.sh"
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(get_project_root)}"

# ============================================================================
# Checksum Fetching Functions
# ============================================================================

# Fetch lazygit checksums from GitHub release
fetch_lazygit_checksums() {
    local version="$1"
    local checksums_file="checksums.txt"

    log_info "Fetching lazygit checksums for version $version..." >&2

    # Fetch checksums file
    local checksums
    if ! checksums=$(fetch_github_checksum_file "jesseduffield/lazygit" "v${version}" "$checksums_file"); then
        return 1
    fi

    # Extract checksums for both architectures
    local amd64_checksum arm64_checksum

    amd64_checksum=$(echo "$checksums" | extract_checksum_from_file "lazygit_${version}_linux_x86_64.tar.gz") || return 1
    arm64_checksum=$(echo "$checksums" | extract_checksum_from_file "lazygit_${version}_linux_arm64.tar.gz") || return 1

    echo "$amd64_checksum $arm64_checksum"
}

# Fetch delta checksums by downloading and calculating SHA256
# Delta doesn't provide checksums in releases, so we calculate them ourselves
fetch_delta_checksums() {
    local version="$1"

    log_info "Fetching delta checksums for version $version..." >&2
    log_info "Note: delta doesn't provide checksums, calculating from downloaded binaries" >&2

    local amd64_url="https://github.com/dandavison/delta/releases/download/${version}/delta-${version}-x86_64-unknown-linux-gnu.tar.gz"
    local arm64_url="https://github.com/dandavison/delta/releases/download/${version}/delta-${version}-aarch64-unknown-linux-gnu.tar.gz"

    # Download and calculate AMD64 checksum
    local amd64_checksum
    log_info "Downloading AMD64 binary to calculate checksum..." >&2
    amd64_checksum=$(curl -fsSL "$amd64_url" | sha256sum | awk '{print $1}')

    if ! validate_sha256 "$amd64_checksum"; then
        log_error "Failed to calculate valid AMD64 checksum" >&2
        return 1
    fi

    # Download and calculate ARM64 checksum
    local arm64_checksum
    log_info "Downloading ARM64 binary to calculate checksum..." >&2
    arm64_checksum=$(curl -fsSL "$arm64_url" | sha256sum | awk '{print $1}')

    if ! validate_sha256 "$arm64_checksum"; then
        log_error "Failed to calculate valid ARM64 checksum" >&2
        return 1
    fi

    echo "$amd64_checksum $arm64_checksum"
}

# Fetch act checksums from GitHub release
fetch_act_checksums() {
    local version="$1"
    local checksums_file="checksums.txt"

    log_info "Fetching act checksums for version $version..." >&2

    # Fetch checksums file
    local checksums
    if ! checksums=$(fetch_github_checksum_file "nektos/act" "v${version}" "$checksums_file"); then
        return 1
    fi

    # Extract checksums for both architectures
    local amd64_checksum arm64_checksum

    amd64_checksum=$(echo "$checksums" | extract_checksum_from_file "act_Linux_x86_64.tar.gz") || return 1
    arm64_checksum=$(echo "$checksums" | extract_checksum_from_file "act_Linux_arm64.tar.gz") || return 1

    echo "$amd64_checksum $arm64_checksum"
}

# Fetch git-cliff checksums from GitHub release (uses SHA512)
# git-cliff provides individual .sha512 files for each asset
fetch_gitcliff_checksums() {
    local version="$1"

    log_info "Fetching git-cliff checksums for version $version (SHA512)..." >&2

    # Fetch AMD64 SHA512
    local amd64_url="https://github.com/orhun/git-cliff/releases/download/v${version}/git-cliff-${version}-x86_64-unknown-linux-gnu.tar.gz.sha512"
    local amd64_checksum

    log_info "Fetching AMD64 SHA512..." >&2
    amd64_checksum=$(curl -fsSL "$amd64_url" | awk '{print $1}')

    if ! validate_sha512 "$amd64_checksum"; then
        log_error "Invalid SHA512 checksum for AMD64: $amd64_checksum" >&2
        return 1
    fi

    # Fetch ARM64 SHA512
    local arm64_url="https://github.com/orhun/git-cliff/releases/download/v${version}/git-cliff-${version}-aarch64-unknown-linux-gnu.tar.gz.sha512"
    local arm64_checksum

    log_info "Fetching ARM64 SHA512..." >&2
    arm64_checksum=$(curl -fsSL "$arm64_url" | awk '{print $1}')

    if ! validate_sha512 "$arm64_checksum"; then
        log_error "Invalid SHA512 checksum for ARM64: $arm64_checksum" >&2
        return 1
    fi

    echo "$amd64_checksum $arm64_checksum"
}

# ============================================================================
# Update Functions
# ============================================================================

update_lazygit_checksums() {
    local version="$1"
    local script_path="$PROJECT_ROOT/$FEATURE_SCRIPT"

    log_info "Updating lazygit checksums for version $version..."

    # Fetch checksums
    local checksums
    if ! checksums=$(fetch_lazygit_checksums "$version"); then
        log_error "Failed to fetch lazygit checksums"
        return 1
    fi

    local amd64_checksum=$(echo "$checksums" | awk '{print $1}')
    local arm64_checksum=$(echo "$checksums" | awk '{print $2}')

    log_info "  AMD64: $amd64_checksum"
    log_info "  ARM64: $arm64_checksum"

    # Update checksums in script
    update_checksum_variable "$script_path" "LAZYGIT_AMD64_SHA256" "$amd64_checksum" || return 1
    update_checksum_variable "$script_path" "LAZYGIT_ARM64_SHA256" "$arm64_checksum" || return 1

    log_success "lazygit checksums updated"
}

update_delta_checksums() {
    local version="$1"
    local script_path="$PROJECT_ROOT/$FEATURE_SCRIPT"

    log_info "Updating delta checksums for version $version..."

    # Fetch checksums
    local checksums
    if ! checksums=$(fetch_delta_checksums "$version"); then
        log_error "Failed to fetch delta checksums"
        return 1
    fi

    local amd64_checksum=$(echo "$checksums" | awk '{print $1}')
    local arm64_checksum=$(echo "$checksums" | awk '{print $2}')

    log_info "  AMD64: $amd64_checksum"
    log_info "  ARM64: $arm64_checksum"

    # Update checksums in script
    update_checksum_variable "$script_path" "DELTA_AMD64_SHA256" "$amd64_checksum" || return 1
    update_checksum_variable "$script_path" "DELTA_ARM64_SHA256" "$arm64_checksum" || return 1

    log_success "delta checksums updated"
}

update_act_checksums() {
    local version="$1"
    local script_path="$PROJECT_ROOT/$FEATURE_SCRIPT"

    log_info "Updating act checksums for version $version..."

    # Fetch checksums
    local checksums
    if ! checksums=$(fetch_act_checksums "$version"); then
        log_error "Failed to fetch act checksums"
        return 1
    fi

    local amd64_checksum=$(echo "$checksums" | awk '{print $1}')
    local arm64_checksum=$(echo "$checksums" | awk '{print $2}')

    log_info "  AMD64: $amd64_checksum"
    log_info "  ARM64: $arm64_checksum"

    # Update checksums in script
    update_checksum_variable "$script_path" "ACT_AMD64_SHA256" "$amd64_checksum" || return 1
    update_checksum_variable "$script_path" "ACT_ARM64_SHA256" "$arm64_checksum" || return 1

    log_success "act checksums updated"
}

update_gitcliff_checksums() {
    local version="$1"
    local script_path="$PROJECT_ROOT/$FEATURE_SCRIPT"

    log_info "Updating git-cliff checksums for version $version (SHA512)..."

    # Fetch checksums
    local checksums
    if ! checksums=$(fetch_gitcliff_checksums "$version"); then
        log_error "Failed to fetch git-cliff checksums"
        return 1
    fi

    local amd64_checksum=$(echo "$checksums" | awk '{print $1}')
    local arm64_checksum=$(echo "$checksums" | awk '{print $2}')

    log_info "  AMD64 (SHA512): $amd64_checksum"
    log_info "  ARM64 (SHA512): $arm64_checksum"

    # Update checksums in script (using SHA512)
    update_checksum_variable "$script_path" "GITCLIFF_AMD64_SHA512" "$amd64_checksum" || return 1
    update_checksum_variable "$script_path" "GITCLIFF_ARM64_SHA512" "$arm64_checksum" || return 1

    log_success "git-cliff checksums updated"
}

# ============================================================================
# Main
# ============================================================================

main() {
    local lazygit_ver="${1:-}"
    local delta_ver="${2:-}"
    local act_ver="${3:-}"
    local gitcliff_ver="${4:-}"

    # Check if feature script exists
    if [ ! -f "$PROJECT_ROOT/$FEATURE_SCRIPT" ]; then
        log_error "Feature script not found: $FEATURE_SCRIPT"
        exit 1
    fi

    log_info "=== Dev Tools Checksum Updater ==="
    log_info "Feature script: $FEATURE_SCRIPT"
    echo ""

    local updated=false
    local failed=false

    # Update lazygit checksums if version provided
    if [ -n "$lazygit_ver" ]; then
        if update_lazygit_checksums "$lazygit_ver"; then
            updated=true
        else
            log_error "Failed to update lazygit checksums"
            failed=true
        fi
        echo ""
    fi

    # Update delta checksums if version provided
    if [ -n "$delta_ver" ]; then
        if update_delta_checksums "$delta_ver"; then
            updated=true
        else
            log_error "Failed to update delta checksums"
            failed=true
        fi
        echo ""
    fi

    # Update act checksums if version provided
    if [ -n "$act_ver" ]; then
        if update_act_checksums "$act_ver"; then
            updated=true
        else
            log_error "Failed to update act checksums"
            failed=true
        fi
        echo ""
    fi

    # Update git-cliff checksums if version provided
    if [ -n "$gitcliff_ver" ]; then
        if update_gitcliff_checksums "$gitcliff_ver"; then
            updated=true
        else
            log_error "Failed to update git-cliff checksums"
            failed=true
        fi
        echo ""
    fi

    # Update verification date
    if [ "$updated" = true ]; then
        local current_date=$(get_current_date)
        update_version_comment "$PROJECT_ROOT/$FEATURE_SCRIPT" "# Checksums verified on:" "$current_date"
        echo ""
    fi

    if [ "$updated" = true ] && [ "$failed" = false ]; then
        log_success "All dev tools checksums updated successfully!"
        return 0
    elif [ "$updated" = true ] && [ "$failed" = true ]; then
        log_warning "Some checksums updated, but some failed"
        return 1
    else
        log_info "No versions provided, nothing to update"
        log_info "Usage: $0 [LAZYGIT_VER] [DELTA_VER] [ACT_VER] [GITCLIFF_VER]"
        return 1
    fi
}

# Run main with all arguments
main "$@"
