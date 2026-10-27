#!/bin/bash
# Go Programming Language - Compiler, runtime, and development tools
#
# Description:
#   Installs the Go programming language with common development tools.
#   Configures workspace and cache directories for optimal container usage.
#
# Features:
#   - Go compiler and runtime, installed by luggage (binary-tarball method,
#     tier-1 GPG signature verification against the catalog's pinned
#     keyrings/golang.asc) from the containers-db catalog
#   - amd64 and arm64 only, matching docs/reference/supported-platforms.md.
#     The pre-luggage script also mapped armhf/i386, platforms this project
#     never built; luggage now refuses them by name ("no install method for
#     go@X matches debian/armhf").
#   - Basic Go tools (gofmt, go vet, etc.)
#   - Module support
#   - Proper cache directory configuration
#
# Cache Strategy:
#   - Uses /cache/go for workspace and /cache/go-build for build cache
#   - Allows volume mounting for persistent module cache across container rebuilds
#
# Environment Variables:
#   - GO_VERSION: Version specification (default: 1.27.2)
#     * Major.minor only (e.g., "1.26"): Resolves to the newest 1.26.x in the
#       luggage catalog
#     * Specific version (e.g., "1.26.3"): Uses exact version
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

source /tmp/build-scripts/base/cache-utils.sh

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
GO_VERSION="${GO_VERSION:-1.27.3}"

# Validate Go version format to prevent shell injection
validate_go_version "$GO_VERSION" || {
    log_error "Build failed due to invalid GO_VERSION"
    exit 1
}

# The catalog starts at 1.22.0, so an older request cannot install. Refuse it
# here, by name, rather than letting it surface as a luggage "no matching
# version" error. Both "1.21" and "1.21.5" carry their major.minor up front.
GO_MAJOR=$(echo "$GO_VERSION" | command cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | command cut -d. -f2)
if [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 22 ]; then
    log_error "Go ${GO_VERSION} is not supported: the luggage catalog starts at 1.22.0"
    exit 1
fi

# Resolve a partial version ("1.26") to the newest patch the luggage catalog
# holds (e.g. "1.26.10"). The catalog is the single source of truth for which
# patches exist and are supported: asking upstream could pick a patch the
# catalog lacks, which then fails to install, and it breaks offline builds.
# `luggage install go@1.26` resolves the same way on its own; resolving here
# only makes the log and the feature summary name the version actually
# installed.
#
# The top-level `version` key is read with sed rather than jq, which no base
# image guarantees. luggage pretty-prints with a two-space indent, so the
# top-level key is the only `"version": "…"` at exactly that depth — a
# dependency's own `version` field prints deeper and is skipped. luggage's own
# stderr is kept so a failure says why (missing version, bad catalog path,
# broken binary) instead of always blaming the catalog.
if [[ "$GO_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ORIGINAL_VERSION="$GO_VERSION"
    resolve_err=$(command mktemp)
    if ! resolve_json=$(/usr/local/bin/luggage resolve go \
        --version "$ORIGINAL_VERSION" \
        --catalog "${CONTAINERS_DB:-/opt/containers-db}" \
        --json 2>"$resolve_err"); then
        log_error "Could not resolve Go ${ORIGINAL_VERSION} via luggage (catalog: ${CONTAINERS_DB:-/opt/containers-db}):"
        log_error "$(command cat "$resolve_err")"
        command rm -f "$resolve_err"
        exit 1
    fi
    command rm -f "$resolve_err"
    GO_VERSION=$(printf '%s\n' "$resolve_json" |
        command sed -n 's/^  "version": "\([^"]*\)",\{0,1\}$/\1/p')
    if [ -z "$GO_VERSION" ]; then
        log_error "luggage resolved Go ${ORIGINAL_VERSION} but its output carried no top-level version"
        exit 1
    fi

    if [ "$ORIGINAL_VERSION" != "$GO_VERSION" ]; then
        log_message "📍 Version Resolution: $ORIGINAL_VERSION → $GO_VERSION"
        log_message "   Newest patch in the luggage catalog"
    fi
fi

# Start logging
log_feature_start "Golang" "${GO_VERSION}"

# ============================================================================
# System Dependencies
# ============================================================================
# luggage installs the catalog's own dependencies (ca-certificates). git is
# not a Go install dependency — `go get` / module fetches need it at runtime —
# so the catalog does not declare it and it stays here.
log_message "Installing system dependencies for Go..."

apt_update
apt_install git

# ============================================================================
# Go Installation (delegated to luggage)
# ============================================================================
# luggage picks the artifact for this platform's arch, downloads it,
# verifies Google's detached .asc signature over it against the catalog's
# pinned keyrings/golang.asc (tier 1, #1508), extracts it under
# /usr/local, creates + chowns the GOPATH/GOCACHE/GOMODCACHE cache dirs, links
# go and gofmt into /usr/local/bin, and validates with `go version`.
log_message "Installing Go via luggage..."

log_command "luggage install go@${GO_VERSION}" \
    /usr/local/bin/luggage install "go@${GO_VERSION}" \
    --catalog "${CONTAINERS_DB:-/opt/containers-db}" \
    --user "${USERNAME}" \
    --cache-root /cache \
    --log-dir /var/log/luggage

# ============================================================================
# Cache and Path Configuration
# ============================================================================
log_message "Configuring Go cache and paths..."

# ALWAYS use /cache paths for consistency with other languages. luggage
# created the three roots from the catalog's cache_dirs; the GOPATH
# subdirectories are a workspace convention, not install layout.
GOPATH="/cache/go"
GOCACHE="/cache/go-build"
GOMODCACHE="/cache/go-mod"

create_cache_directories "${GOPATH}/bin" "${GOPATH}/src" "${GOPATH}/pkg"

log_message "Go installation paths:"
log_message "  GOROOT: /usr/local/go"
log_message "  GOPATH: ${GOPATH}"
log_message "  GOCACHE: ${GOCACHE}"
log_message "  GOMODCACHE: ${GOMODCACHE}"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide Go environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Go configuration (content in lib/bashrc/golang-env.sh)
write_bashrc_content /etc/bashrc.d/50-golang.sh "Go environment configuration" \
    </tmp/build-scripts/features/lib/bashrc/golang-env.sh

log_command "Setting Go bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-golang.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Go aliases and helpers..."

# Go aliases and helpers (content in lib/bashrc/golang-aliases.sh)
write_bashrc_content /etc/bashrc.d/50-golang.sh "Go aliases and helpers" \
    </tmp/build-scripts/features/lib/bashrc/golang-aliases.sh

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
log_feature_instructions "test-go" "golang"
