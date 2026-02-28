#!/bin/bash
# Go Programming Language - Compiler, runtime, and development tools
#
# Description:
#   Installs the Go programming language with common development tools.
#   Configures workspace and cache directories for optimal container usage.
#
# Features:
#   - Go compiler and runtime with 4-tier checksum verification
#   - Basic Go tools (gofmt, go vet, etc.)
#   - Module support
#   - Proper cache directory configuration
#
# Cache Strategy:
#   - Uses /cache/go for workspace and /cache/go-build for build cache
#   - Allows volume mounting for persistent module cache across container rebuilds
#
# Environment Variables:
#   - GO_VERSION: Version specification (default: 1.25.3)
#     * Major.minor only (e.g., "1.23"): Resolves to latest 1.23.x with pinned checksum
#     * Specific version (e.g., "1.23.5"): Uses exact version
#   - GOPATH: Go workspace directory (default: /cache/go)
#   - GOCACHE: Go build cache (default: /cache/go-build)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source version resolution for partial version support
source /tmp/build-scripts/base/version-resolution.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Source checksum fetching utilities
source /tmp/build-scripts/base/checksum-fetch.sh

# Source 4-tier checksum verification system
source /tmp/build-scripts/base/checksum-verification.sh
source /tmp/build-scripts/base/cache-utils.sh

# Source path utilities for secure PATH management
source /tmp/build-scripts/base/path-utils.sh

# ============================================================================
# Template Loading Helper
# ============================================================================
# load_go_template - Load a Go project template file and perform substitutions
#
# Arguments:
#   $1 - Template path relative to templates/go/ (required)
#   $2 - Project name for __PROJECT__ substitution (optional)
#
# Example:
#   load_go_template "common/gitignore.tmpl"
#   load_go_template "lib/lib.go.tmpl" "myproject"
# ============================================================================
load_go_template() {
    local template_path="$1"
    local project_name="${2:-}"
    local template_file="/tmp/build-scripts/features/templates/go/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$project_name" ]; then
        # Replace __PROJECT__ placeholder with actual project name
        command sed "s/__PROJECT__/${project_name}/g" "$template_file"
    else
        # No substitution needed, just output the template
        command cat "$template_file"
    fi
}

# ============================================================================
# Version Configuration
# ============================================================================
GO_VERSION="${GO_VERSION:-1.25.3}"

# Validate Go version format to prevent shell injection
validate_go_version "$GO_VERSION" || {
    log_error "Build failed due to invalid GO_VERSION"
    exit 1
}

# Resolve partial versions to full versions (e.g., "1.23" -> "1.23.5")
# This enables users to use partial versions and get latest patches with pinned checksums
if [[ "$GO_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ORIGINAL_VERSION="$GO_VERSION"
    GO_VERSION=$(resolve_go_version "$GO_VERSION" 2>/dev/null || echo "$GO_VERSION")

    if [ "$ORIGINAL_VERSION" != "$GO_VERSION" ]; then
        log_message "📍 Version Resolution: $ORIGINAL_VERSION → $GO_VERSION"
        log_message "   Using latest patch version with pinned checksum verification"
    fi
fi

# Extract major.minor version for comparison
GO_MAJOR=$(echo "$GO_VERSION" | command cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | command cut -d. -f2)

# Start logging
log_feature_start "Golang" "${GO_VERSION}"

# Go releases are supported for 2 major versions
# As of July 2025, Go 1.22 would be the minimum supported
if [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 22 ]; then
    log_warning "Go $GO_VERSION is outdated"
    log_warning "Go versions older than 1.22 are no longer supported"
    log_warning "Continuing with installation, but consider upgrading"
fi

# ============================================================================
# Architecture Detection
# ============================================================================
log_message "Detecting system architecture..."

# Detect architecture
ARCH=$(dpkg --print-architecture)
case ${ARCH} in
    amd64)
        GO_ARCH="amd64"
        ;;
    arm64|aarch64)
        GO_ARCH="arm64"
        ;;
    armhf)
        GO_ARCH="armv6l"
        ;;
    386|i386)
        GO_ARCH="386"
        ;;
    *)
        log_error "Unsupported architecture: ${ARCH}"
        log_feature_end
        exit 1
        ;;
esac

log_message "Architecture: ${GO_ARCH}"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Go..."

# Update package lists with retry logic
apt_update

# Install system dependencies with retry logic
apt_install \
    curl \
    ca-certificates \
    git

# ============================================================================
# Go Installation
# ============================================================================
log_message "Downloading and installing Go ${GO_VERSION}..."

BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

# Download Go tarball with 4-tier checksum verification
GO_TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
GO_URL="https://go.dev/dl/${GO_TARBALL}"

# Download Go tarball
log_message "Downloading Go ${GO_VERSION} for ${GO_ARCH}..."
if ! command curl -fsSL "$GO_URL" -o "$GO_TARBALL"; then
    log_error "Failed to download Go ${GO_VERSION}"
    log_error "Please verify version exists: https://go.dev/dl/#go${GO_VERSION}"
    log_feature_end
    exit 1
fi

# Verify using 4-tier system (GPG → Pinned → Published → Calculated)
# This will try each tier in order and log which method succeeded
# Exit codes: 0=verified, 1=failed, 2=unverified (TOFU fallback)
_verify_rc=0
verify_download "language" "go" "$GO_VERSION" "$GO_TARBALL" "$GO_ARCH" || _verify_rc=$?
if [ "$_verify_rc" -eq 1 ]; then
    log_error "Checksum verification failed for Go ${GO_VERSION}"
    log_feature_end
    exit 1
elif [ "$_verify_rc" -eq 2 ]; then
    log_warning "Download accepted without external verification (TOFU)"
fi

# Extract Go to /usr/local
log_command "Extracting Go to /usr/local" \
    tar -xzf "$GO_TARBALL" -C /usr/local

# Clean up
cd /
log_command "Cleaning up Go build directory" \
    command rm -rf "$BUILD_TEMP"

# ============================================================================
# Cache and Path Configuration
# ============================================================================
log_message "Configuring Go cache and paths..."

# ALWAYS use /cache paths for consistency with other languages
# This will either use cache mount (faster rebuilds) or be created in the image
GOPATH="/cache/go"
GOCACHE="/cache/go-build"
GOMODCACHE="/cache/go-mod"

# Create cache directories with correct ownership
# Use shared utility for atomic directory creation with correct ownership
# Important: Create parent /cache/go directory first to ensure correct ownership
create_cache_directories "${GOPATH}" "${GOPATH}/bin" "${GOPATH}/src" "${GOPATH}/pkg" "${GOCACHE}" "${GOMODCACHE}"

log_message "Go installation paths:"
log_message "  GOROOT: /usr/local/go"
log_message "  GOPATH: ${GOPATH}"
log_message "  GOCACHE: ${GOCACHE}"
log_message "  GOMODCACHE: ${GOMODCACHE}"

# ============================================================================
# Create symlinks for Go binaries
# ============================================================================
log_message "Creating Go symlinks..."

# Create /usr/local/bin symlinks for consistency with other languages
for cmd in go gofmt; do
    if [ -f "/usr/local/go/bin/${cmd}" ]; then
        create_symlink "/usr/local/go/bin/${cmd}" "/usr/local/bin/${cmd}" "${cmd} command"
    fi
done


# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide Go environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Go configuration (content in lib/bashrc/golang-env.sh)
write_bashrc_content /etc/bashrc.d/50-golang.sh "Go environment configuration" \
    < /tmp/build-scripts/features/lib/bashrc/golang-env.sh

log_command "Setting Go bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-golang.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Go aliases and helpers..."

# Go aliases and helpers (content in lib/bashrc/golang-aliases.sh)
write_bashrc_content /etc/bashrc.d/50-golang.sh "Go aliases and helpers" \
    < /tmp/build-scripts/features/lib/bashrc/golang-aliases.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
echo "=== Creating Go startup script ==="

# Create startup directory if it doesn't exist
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

install -m 755 /tmp/build-scripts/features/lib/golang/30-go-setup.sh \
    /etc/container/first-startup/30-go-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Go verification script..."

install -m 755 /tmp/build-scripts/features/lib/golang/test-go.sh \
    /usr/local/bin/test-go

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Go installation..."

log_command "Checking Go version" \
    /usr/local/bin/go version || log_warning "Go not installed properly"

# Export directory paths for feature summary (also defined in bashrc for runtime)
export GOPATH="/cache/go"
export GOCACHE="/cache/go-build"
export GOMODCACHE="/cache/go-mod"

# Log feature summary
log_feature_summary \
    --feature "Go" \
    --version "${GO_VERSION}" \
    --tools "go,gofmt" \
    --paths "${GOPATH},${GOCACHE},${GOMODCACHE}" \
    --env "GOROOT,GOPATH,GOCACHE,GOMODCACHE,GO111MODULE,GOPROXY,GOSUMDB" \
    --commands "go,gofmt,gob,gor,got,gom,gomt,go-init,go-bench,go-cover" \
    --next-steps "Run 'test-go' to verify installation. Use 'go-init <module-name> [cli|lib|api]' to create new projects."

# End logging
log_feature_end

echo ""
echo "Cache directories configured:"
echo "  GOPATH: ${GOPATH}"
echo "  GOCACHE: ${GOCACHE}"
echo "  GOMODCACHE: ${GOMODCACHE}"
echo ""
echo "Run 'test-go' to verify Go installation"
echo "Run 'check-build-logs.sh golang' to review installation logs"
