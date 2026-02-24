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
GO_MAJOR=$(echo "$GO_VERSION" | cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | cut -d. -f2)

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
if ! verify_download "language" "go" "$GO_VERSION" "$GO_TARBALL" "$GO_ARCH"; then
    log_error "Checksum verification failed for Go ${GO_VERSION}"
    log_feature_end
    exit 1
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

# Create system-wide Go configuration
write_bashrc_content /etc/bashrc.d/50-golang.sh "Go environment configuration" << 'GOLANG_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Go environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Go environment variables
export GOROOT=/usr/local/go
export GOPATH="/cache/go"
export GOCACHE="/cache/go-build"
export GOMODCACHE="/cache/go-mod"

# Add Go binaries to PATH with security validation
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "${GOPATH}/bin" 2>/dev/null || export PATH="${GOPATH}/bin:$PATH"
    safe_add_to_path "/usr/local/go/bin" 2>/dev/null || export PATH="/usr/local/go/bin:$PATH"
else
    # Fallback if safe_add_to_path not available
    export PATH="${GOPATH}/bin:/usr/local/go/bin:$PATH"
fi

# Go proxy settings for faster module downloads
export GOPROXY="https://proxy.golang.org,direct"
export GOSUMDB="sum.golang.org"

# Enable Go modules by default
export GO111MODULE=on

GOLANG_BASHRC_EOF

log_command "Setting Go bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-golang.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Go aliases and helpers..."

write_bashrc_content /etc/bashrc.d/50-golang.sh "Go aliases and helpers" << 'GOLANG_BASHRC_EOF'

# ----------------------------------------------------------------------------
# Go Aliases
# ----------------------------------------------------------------------------
alias gob='go build'
alias gor='go run'
alias got='go test'
alias gotv='go test -v'
alias gotc='go test -cover'
alias gof='go fmt'
alias gom='go mod'
alias gomt='go mod tidy'
alias gomd='go mod download'
alias gomi='go mod init'
alias gomv='go mod vendor'
alias gols='go list'

# ----------------------------------------------------------------------------
# go-init - Create a new Go module project
#
# Arguments:
#   $1 - Module name (required, e.g., github.com/user/project)
#   $2 - Project type (optional: cli, lib, api, default: lib)
#
# Example:
#   go-init github.com/myuser/myproject cli
# ----------------------------------------------------------------------------
go-init() {
    if [ -z "$1" ]; then
        echo "Usage: go-init <module-name> [type]"
        echo "Types: cli, lib, api"
        return 1
    fi

    local module_name="$1"
    local project_type="${2:-lib}"

    # Validate module name format (typical Go module path)
    if ! [[ "$module_name" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        echo "Error: Invalid module name format" >&2
        echo "Module name should contain only alphanumeric, dots, dashes, slashes, and underscores" >&2
        return 1
    fi

    # Validate project type
    case "$project_type" in
        cli|lib|api)
            # Valid types
            ;;
        *)
            echo "Error: Invalid project type '$project_type'" >&2
            echo "Valid types: cli, lib, api" >&2
            return 1
            ;;
    esac

    local project_dir=$(basename "$module_name")

    # Sanitize project directory name (remove any path traversal attempts)
    project_dir=$(echo "$project_dir" | tr -cd 'a-zA-Z0-9._-')

    if [ -z "$project_dir" ] || [ "$project_dir" = "." ] || [ "$project_dir" = ".." ]; then
        echo "Error: Invalid project directory name after sanitization" >&2
        return 1
    fi

    echo "Creating new Go project: $module_name (type: $project_type)"

    # Create project directory
    mkdir -p "$project_dir"
    cd "$project_dir" || return 1

    # Initialize go module
    go mod init "$module_name"

    # Create standard Go project structure
    mkdir -p cmd pkg internal test docs

    # Create .gitignore
    load_go_template "common/gitignore.tmpl" > .gitignore

    # Create type-specific files
    case "$project_type" in
        cli)
            mkdir -p cmd/${project_dir}
            load_go_template "cli/main.go.tmpl" > cmd/${project_dir}/main.go
            ;;
        api)
            load_go_template "api/main.go.tmpl" > main.go
            ;;
        *)
            # Default library setup
            load_go_template "lib/lib.go.tmpl" "$project_dir" > ${project_dir}.go
            load_go_template "lib/lib_test.go.tmpl" "$project_dir" > ${project_dir}_test.go
            ;;
    esac

    # Create Makefile
    load_go_template "common/Makefile.tmpl" > Makefile

    echo "Project $project_dir created successfully!"
    echo ""
    echo "Next steps:"
    echo "  cd $project_dir"
    echo "  go mod tidy"
    echo "  make test"
}

# ----------------------------------------------------------------------------
# go-bench - Run benchmarks with nice output
#
# Arguments:
#   $@ - Additional arguments to pass to go test -bench
#
# Example:
#   go-bench
#   go-bench -benchtime=10s
# ----------------------------------------------------------------------------
go-bench() {
    echo "Running Go benchmarks..."
    go test -bench=. -benchmem "$@" | tee benchmark_results.txt
    echo ""
    echo "Results saved to benchmark_results.txt"
}

# ----------------------------------------------------------------------------
# go-cover - Run tests with coverage and open HTML report
# ----------------------------------------------------------------------------
go-cover() {
    echo "Running tests with coverage..."
    go test -coverprofile=coverage.out ./...
    go tool cover -html=coverage.out -o coverage.html
    echo "Coverage report generated: coverage.html"

    # Try to open in browser if possible
    if command -v xdg-open &> /dev/null; then
        xdg-open coverage.html
    elif command -v open &> /dev/null; then
        open coverage.html
    fi
}

# ----------------------------------------------------------------------------
# go-deps - Show module dependencies as a tree
# ----------------------------------------------------------------------------
go-deps() {
    if [ -f go.mod ]; then
        echo "=== Direct dependencies ==="
        go list -m -f '{{.Path}} {{.Version}}' all | grep -v '^[[:space:]]'
        echo ""
        echo "=== Full dependency tree ==="
        go mod graph
    else
        echo "No go.mod found in current directory"
    fi
}

# ----------------------------------------------------------------------------
# go-update - Update all dependencies to latest versions
# ----------------------------------------------------------------------------
go-update() {
    if [ -f go.mod ]; then
        echo "Updating Go dependencies to latest versions..."
        go get -u ./...
        go mod tidy
        echo "Dependencies updated. Run 'go test ./...' to verify."
    else
        echo "No go.mod found in current directory"
    fi
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
GOLANG_BASHRC_EOF

# ============================================================================
# Container Startup Scripts
# ============================================================================
echo "=== Creating Go startup script ==="

# Create startup directory if it doesn't exist
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/30-go-setup.sh << 'EOF'
#!/bin/bash
# Go development environment setup

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Set up Go environment
export GOPATH="/cache/go"
export GOCACHE="/cache/go-build"
export GOMODCACHE="/cache/go-mod"

# Add Go binaries to PATH with security validation
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "${GOPATH}/bin" 2>/dev/null || export PATH="${GOPATH}/bin:$PATH"
    safe_add_to_path "/usr/local/go/bin" 2>/dev/null || export PATH="/usr/local/go/bin:$PATH"
else
    # Fallback if safe_add_to_path not available
    export PATH="${GOPATH}/bin:/usr/local/go/bin:$PATH"
fi

# Check for Go projects (only if WORKING_DIR is set)
if [ -n "${WORKING_DIR:-}" ] && [ -f "${WORKING_DIR}/go.mod" ]; then
    echo "=== Go Project Detected ==="
    echo "Go $(go version | awk '{print $3}') is installed"
    echo "GOPATH: ${GOPATH}"
    echo "Module: $(head -1 "${WORKING_DIR}/go.mod" | awk '{print $2}')"

    cd "${WORKING_DIR}"

    # Download dependencies
    echo "Downloading Go module dependencies..."
    go mod download || echo "Note: Some dependencies may have failed to download"

    # Verify dependencies
    if go mod verify &> /dev/null; then
        echo "✓ All dependencies verified"
    else
        echo "⚠ Some dependencies could not be verified"
    fi

    echo ""
    echo "Common commands:"
    echo "  go build    - Build the project"
    echo "  go test     - Run tests"
    echo "  go run .    - Run the application"
    echo "  go vet      - Run Go vet"
fi

# Show available Go tools
if command -v go &> /dev/null; then
    echo ""
    echo "Go development tools:"
    echo "  For development tools like gopls, dlv, golangci-lint,"
    echo "  goimports, etc., enable the golang-dev feature."
    echo ""
    echo "Create new projects:"
    echo "  go-init <module-name> [cli|lib|api]"
fi
EOF

log_command "Setting startup script permissions" \
    chmod +x /etc/container/first-startup/30-go-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Go verification script..."

command cat > /usr/local/bin/test-go << 'EOF'
#!/bin/bash
echo "=== Go Installation Status ==="
if command -v go &> /dev/null; then
    go version
    echo "Go binary: $(which go)"
    echo "GOROOT: ${GOROOT:-/usr/local/go}"
    echo "GOPATH: ${GOPATH:-/cache/go}"
    echo "GOCACHE: ${GOCACHE:-/cache/go-build}"
    echo "GOMODCACHE: ${GOMODCACHE:-/cache/go-mod}"
else
    echo "✗ Go is not installed"
fi

EOF

log_command "Setting test-go script permissions" \
    chmod +x /usr/local/bin/test-go

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
