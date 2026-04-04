#!/bin/bash
# Go Development Tools - Advanced development utilities for Go
#
# Description:
#   Installs additional development tools for Go programming, including
#   code analysis, testing, benchmarking, and documentation tools. These
#   complement the base Go installation with productivity-enhancing utilities.
#
# Tools Installed:
#   Core Development Tools:
#     - gopls: Official Go language server
#     - dlv: Delve debugger
#     - golangci-lint: Meta linter
#     - goimports: Import formatter
#     - gomodifytags: Modify struct field tags
#     - impl: Generate method stubs for interfaces
#     - goplay: Go playground client
#   Additional Analysis Tools:
#     - staticcheck: Advanced static analysis
#     - gocyclo: Cyclomatic complexity analyzer
#     - ineffassign: Detects ineffectual assignments
#     - revive: Fast, extensible linter
#     - errcheck: Checks for unchecked errors
#     - gosec: Security checker
#     - go-critic: Opinionated code critic
#     - gocognit: Cognitive complexity analyzer
#     - goconst: Find repeated strings
#     - godot: Check comment periods
#     - gomodifytags: Modify struct field tags (already in base)
#     - gotests: Generate tests from functions
#     - gomock: Mocking framework
#     - go-callvis: Visualize call graph
#     - goda: Go dependency analysis
#     - govulncheck: Check for known vulnerabilities
#     - benchstat: Compare benchmark results
#     - pprof: CPU and memory profiler (built-in)
#     - stress: Stress test runner
#     - richgo: Rich test output
#     - goreleaser: Release automation
#     - ko: Container image builder
#     - air: Live reload for Go apps
#     - swag: Swagger documentation generator
#     - mockgen: Generate mocks for interfaces
#     - wire: Dependency injection
#   Documentation:
#     - godoc: Go documentation server
#   Protocol Buffers:
#     - protoc-gen-go: Protocol buffer compiler plugin for Go
#     - protoc-gen-go-grpc: gRPC plugin for Protocol buffers
#
# Requirements:
#   - Go must be installed (via INCLUDE_GOLANG=true)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source path utilities for secure PATH management
source /tmp/build-scripts/base/path-utils.sh

# Start logging
log_feature_start "Golang Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
require_feature_binary "/usr/local/bin/go" "INCLUDE_GOLANG"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Go dev tools..."

# Update package lists with retry logic
apt_update

# Install system dependencies with retry logic
# build-essential provides gcc, g++, make needed for CGO compilation
# binutils-gold provides gold linker (ld.gold) required by Go for external linking on ARM64
#   Note: Gold linker is deprecated as of GNU Binutils 2.44 (Feb 2025), but:
#   - Go 1.24 still requires it for external linking on ARM64 (see Go issue #22040)
#   - Debian's official golang-go package installs binutils-gold as a dependency
#   - Still maintained in Debian's security updates
#   - Will be updated when Go officially removes the gold requirement
# graphviz needed for go-callvis
# protobuf-compiler needed for protobuf tools
apt_install \
    build-essential \
    binutils-gold \
    graphviz \
    protobuf-compiler

# ============================================================================
# Go Development Tools Installation
# ============================================================================
log_message "Installing Go development tools via go install..."

# Set up Go environment
export GOPATH="/cache/go"
export GOCACHE="/cache/go-build"
export GOMODCACHE="/cache/go-mod"
export PATH="/usr/local/go/bin:$PATH"
export PATH="${GOPATH}/bin:$PATH"

# Core development tools
log_message "Installing core development tools..."
if [ "${SKIP_LSP_INSTALL}" != "true" ]; then
    log_command "Installing gopls (language server)" \
        /usr/local/bin/go install golang.org/x/tools/gopls@latest || true
else
    log_message "Skipping gopls (SKIP_LSP_INSTALL=true)"
fi
log_command "Installing delve debugger" \
    /usr/local/bin/go install github.com/go-delve/delve/cmd/dlv@latest || true
log_command "Installing golangci-lint" \
    /usr/local/bin/go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest || true
log_command "Installing goimports" \
    /usr/local/bin/go install golang.org/x/tools/cmd/goimports@latest || true
log_command "Installing gomodifytags" \
    /usr/local/bin/go install github.com/fatih/gomodifytags@latest || true
log_command "Installing impl" \
    /usr/local/bin/go install github.com/josharian/impl@latest || true
log_command "Installing goplay" \
    /usr/local/bin/go install github.com/haya14busa/goplay/cmd/goplay@latest || true

# Static analysis tools
log_message "Installing static analysis tools..."
log_command "Installing staticcheck" \
    /usr/local/bin/go install honnef.co/go/tools/cmd/staticcheck@latest || true
log_command "Installing gocyclo" \
    /usr/local/bin/go install github.com/fzipp/gocyclo/cmd/gocyclo@latest || true
log_command "Installing ineffassign" \
    /usr/local/bin/go install github.com/gordonklaus/ineffassign@latest || true
log_command "Installing revive" \
    /usr/local/bin/go install github.com/mgechev/revive@latest || true
log_command "Installing errcheck" \
    /usr/local/bin/go install github.com/kisielk/errcheck@latest || true
log_command "Installing gosec" \
    /usr/local/bin/go install github.com/securego/gosec/v2/cmd/gosec@latest || true
log_command "Installing gocritic" \
    /usr/local/bin/go install github.com/go-critic/go-critic/cmd/gocritic@latest || true
log_command "Installing gocognit" \
    /usr/local/bin/go install github.com/uudashr/gocognit/cmd/gocognit@latest || true
log_command "Installing goconst" \
    /usr/local/bin/go install github.com/jgautheron/goconst/cmd/goconst@latest || true
log_command "Installing godot" \
    /usr/local/bin/go install github.com/tetafro/godot/cmd/godot@latest || true

# Testing and mocking tools
log_message "Installing testing tools..."
log_command "Installing gotests" \
    /usr/local/bin/go install github.com/cweill/gotests/gotests@latest || true
log_command "Installing mockgen" \
    /usr/local/bin/go install github.com/golang/mock/mockgen@latest || true
log_command "Installing richgo" \
    /usr/local/bin/go install github.com/kyoh86/richgo@latest || true
log_command "Installing stress" \
    /usr/local/bin/go install golang.org/x/tools/cmd/stress@latest || true
log_command "Installing benchstat" \
    /usr/local/bin/go install golang.org/x/perf/cmd/benchstat@latest || true

# Dependency and visualization tools
log_message "Installing dependency analysis tools..."
log_command "Installing go-callvis" \
    /usr/local/bin/go install github.com/ofabry/go-callvis@latest || true
log_command "Installing goda" \
    /usr/local/bin/go install github.com/loov/goda@latest || true
log_command "Installing govulncheck" \
    /usr/local/bin/go install golang.org/x/vuln/cmd/govulncheck@latest || true
log_command "Installing wire" \
    /usr/local/bin/go install github.com/google/wire/cmd/wire@latest || true

# Development workflow tools
log_message "Installing workflow tools..."
log_command "Installing air (live reload)" \
    /usr/local/bin/go install github.com/air-verse/air@latest || true
log_command "Installing goreleaser" \
    /usr/local/bin/go install github.com/goreleaser/goreleaser/v2@latest || true
log_command "Installing ko (container builder)" \
    /usr/local/bin/go install github.com/google/ko@latest || true

# Documentation tools
log_message "Installing documentation tools..."
log_command "Installing swag (Swagger generator)" \
    /usr/local/bin/go install github.com/swaggo/swag/cmd/swag@latest || true
log_command "Installing godoc" \
    /usr/local/bin/go install golang.org/x/tools/cmd/godoc@latest || true

# Protocol buffer support
log_message "Installing protobuf tools..."
log_command "Installing protoc-gen-go" \
    /usr/local/bin/go install google.golang.org/protobuf/cmd/protoc-gen-go@latest || true
log_command "Installing protoc-gen-go-grpc" \
    /usr/local/bin/go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest || true

# ============================================================================
# Create symlinks for all installed tools
# ============================================================================
log_message "Creating symlinks for Go dev tools..."

# List of all tools to symlink
TOOLS=(
    # Core development tools
    gopls dlv golangci-lint goimports gomodifytags impl goplay
    # Static analysis and linting
    staticcheck gocyclo ineffassign revive errcheck gosec gocritic
    gocognit goconst godot
    # Testing tools
    gotests mockgen richgo stress benchstat govulncheck
    # Analysis and visualization
    go-callvis goda
    # Workflow and build tools
    air goreleaser ko swag godoc wire
    # Protocol buffer tools
    protoc-gen-go protoc-gen-go-grpc
)

for tool in "${TOOLS[@]}"; do
    if [ -f "${GOPATH}/bin/${tool}" ]; then
        create_symlink "${GOPATH}/bin/${tool}" "/usr/local/bin/${tool}" "${tool} Go tool"
    fi
done

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Go development helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add golang-dev aliases and helpers (content in lib/bashrc/golang-dev.sh)
write_bashrc_content /etc/bashrc.d/55-golang-dev.sh "Go development tools configuration" \
    < /tmp/build-scripts/features/lib/bashrc/golang-dev.sh

log_command "Setting golang-dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/55-golang-dev.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating golang-dev startup script..."

log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cp /tmp/build-scripts/features/lib/golang/35-golang-dev-setup.sh \
    /etc/container/first-startup/35-golang-dev-setup.sh

log_command "Setting golang-dev startup script permissions" \
    chmod +x /etc/container/first-startup/35-golang-dev-setup.sh

# ============================================================================
# Create default configurations
# ============================================================================
log_message "Creating default Go development configurations..."

# Create directory for templates
log_command "Creating go-dev-templates directory" \
    mkdir -p /etc/go-dev-templates

# Default .golangci.yml
command cp /tmp/build-scripts/features/lib/golang/golangci.yml \
    /etc/go-dev-templates/.golangci.yml

# Default .air.toml
command cp /tmp/build-scripts/features/lib/golang/air.toml \
    /etc/go-dev-templates/.air.toml

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating golang-dev verification script..."

command cp /tmp/build-scripts/features/lib/golang/test-golang-dev.sh \
    /usr/local/bin/test-golang-dev

log_command "Setting test-golang-dev script permissions" \
    chmod +x /usr/local/bin/test-golang-dev

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying key Go development tools..."

log_command "Checking gopls version" \
    /usr/local/bin/gopls version 2>/dev/null || log_warning "gopls not installed"

log_command "Checking golangci-lint version" \
    /usr/local/bin/golangci-lint version 2>/dev/null || log_warning "golangci-lint not installed"

log_command "Checking staticcheck version" \
    /usr/local/bin/staticcheck -version 2>/dev/null || log_warning "staticcheck not installed"

log_command "Checking air version" \
    /usr/local/bin/air -v 2>/dev/null || log_warning "air not installed"

# Export directory paths for feature summary (also defined in parent golang.sh)
export GOPATH="/cache/go"
export GOCACHE="/cache/go-build"
export GOMODCACHE="/cache/go-mod"

# Log feature summary
log_feature_summary \
    --feature "Go Development Tools" \
    --tools "gopls,dlv,golangci-lint,goimports,gomodifytags,impl,staticcheck,gosec,revive,errcheck,gotests,mockgen,richgo,air,goreleaser,ko,swag,wire,govulncheck" \
    --paths "${GOPATH},${GOCACHE},${GOMODCACHE}" \
    --env "GOPATH,GOCACHE,GOMODCACHE,GOROOT" \
    --commands "gopls,dlv,golangci-lint,goimports,staticcheck,gosec,gotests,mockgen,air,goreleaser,ko,go-lint-all,go-security-check,go-test-coverage,go-live" \
    --next-steps "Run 'test-golang-dev' to check installed tools. Use go-lint-all for comprehensive linting, go-live for hot reload."

# End logging
log_feature_end

log_feature_instructions "test-golang-dev" "golang-development-tools"
