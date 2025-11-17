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
log_message "Checking prerequisites..."

# Check if Go is available
if [ ! -f "/usr/local/bin/go" ]; then
    log_error "go not found at /usr/local/bin/go"
    log_error "The INCLUDE_GOLANG feature must be enabled before golang-dev tools can be installed"
    log_feature_end
    exit 1
fi

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
log_command "Installing gopls (language server)" \
    /usr/local/bin/go install golang.org/x/tools/gopls@latest || true
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

# Add golang-dev aliases and helpers
write_bashrc_content /etc/bashrc.d/55-golang-dev.sh "Go development tools configuration" << 'GOLANG_DEV_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Go Development Tool Aliases and Functions
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Go Development Tool Aliases
# ----------------------------------------------------------------------------
# Linting shortcuts
alias gol='golangci-lint run'
alias gosl='staticcheck ./...'
alias gocyc='gocyclo -over 10 .'
alias gosec='gosec ./...'
alias gorev='revive ./...'
alias goerr='errcheck ./...'
alias gocrit='gocritic check ./...'

# Testing shortcuts
alias gotest='richgo test'
alias gotestv='richgo test -v'
alias gotestc='richgo test -cover'
alias gotesta='richgo test ./...'
alias gobench='go test -bench=. -benchmem'
alias gostress='stress'

# Documentation
alias godocs='godoc -http=:6060'
alias goswag='swag init'

# Build and release
alias gorel='goreleaser'
alias gorelc='goreleaser check'
alias goreld='goreleaser release --skip=publish --clean'

# ----------------------------------------------------------------------------
# go-lint-all - Run all linters
# ----------------------------------------------------------------------------
go-lint-all() {
    echo "=== Running all Go linters ==="

    echo "Running golangci-lint..."
    golangci-lint run ./... || true

    echo -e "\nRunning staticcheck..."
    staticcheck ./... || true

    echo -e "\nRunning gosec..."
    gosec -quiet ./... || true

    echo -e "\nRunning errcheck..."
    errcheck ./... || true

    echo -e "\nRunning ineffassign..."
    ineffassign ./... || true

    echo -e "\nChecking for vulnerabilities..."
    govulncheck ./... || true
}

# ----------------------------------------------------------------------------
# go-security-check - Run security scanners
# ----------------------------------------------------------------------------
go-security-check() {
    echo "=== Running Go security scanners ==="

    echo "Running gosec (static security analysis)..."
    gosec ./... || true

    echo -e "\nRunning govulncheck (vulnerability database)..."
    govulncheck ./... || true
}

# ----------------------------------------------------------------------------
# go-test-coverage - Run tests with detailed coverage report
# ----------------------------------------------------------------------------
go-test-coverage() {
    echo "=== Running tests with coverage ==="

    # Run tests with coverage
    richgo test -coverprofile=coverage.out -covermode=atomic ./...

    # Generate coverage report
    echo -e "\n=== Coverage Summary ==="
    go tool cover -func=coverage.out | tail -n 1

    # Generate HTML report
    go tool cover -html=coverage.out -o coverage.html
    echo -e "\nDetailed coverage report: coverage.html"
}

# ----------------------------------------------------------------------------
# go-generate-tests - Generate test files for functions
#
# Arguments:
#   $1 - File or directory path (optional, defaults to current directory)
#
# Example:
#   go-generate-tests
#   go-generate-tests pkg/utils/
# ----------------------------------------------------------------------------
go-generate-tests() {
    local target="${1:-.}"
    echo "Generating tests for: $target"

    if [ -f "$target" ]; then
        gotests -all -w "$target"
    else
        command find "$target" -name "*.go" -not -name "*_test.go" -not -path "*/vendor/*" | while read -r file; do
            echo "Generating tests for $file"
            gotests -all -w "$file"
        done
    fi
}

# ----------------------------------------------------------------------------
# go-mock-gen - Generate mocks for interfaces
#
# Arguments:
#   $1 - Source file containing interfaces (required)
#   $2 - Destination package (optional, defaults to mocks)
#
# Example:
#   go-mock-gen internal/service/interface.go
#   go-mock-gen internal/service/interface.go internal/mocks
# ----------------------------------------------------------------------------
go-mock-gen() {
    if [ -z "$1" ]; then
        echo "Usage: go-mock-gen <interface-file> [destination-package]"
        return 1
    fi

    local source="$1"
    local dest="${2:-mocks}"
    local source_dir=$(dirname "$source")
    local source_file=$(basename "$source" .go)

    echo "Generating mocks for interfaces in $source"

    # Create destination directory
    mkdir -p "$dest"

    # Generate mock
    mockgen -source="$source" -destination="$dest/mock_${source_file}.go" -package="$(basename $dest)"
}

# ----------------------------------------------------------------------------
# go-visualize - Visualize Go code structure
#
# Arguments:
#   $1 - Package to visualize (optional, defaults to main)
#
# Example:
#   go-visualize
#   go-visualize ./cmd/app
# ----------------------------------------------------------------------------
go-visualize() {
    local pkg="${1:-main}"
    echo "Generating visualization for package: $pkg"

    # Generate call graph
    go-callvis -group pkg,type -focus "$pkg" . &
    local pid=$!

    echo "Visualization server started at http://localhost:7878"
    echo "Press Ctrl+C to stop"

    # Wait for interrupt
    trap "kill $pid 2>/dev/null; exit" INT
    wait $pid
}

# ----------------------------------------------------------------------------
# go-profile-cpu - Profile CPU usage
#
# Arguments:
#   $1 - Command to profile (required)
#   $@ - Additional arguments for the command
#
# Example:
#   go-profile-cpu ./myapp
#   go-profile-cpu go test -bench=.
# ----------------------------------------------------------------------------
go-profile-cpu() {
    if [ -z "$1" ]; then
        echo "Usage: go-profile-cpu <command> [args...]"
        return 1
    fi

    echo "Profiling CPU usage..."

    # Run with CPU profiling
    CPUPROFILE=cpu.prof $@

    echo "Opening profile in browser..."
    go tool pprof -http=:8080 cpu.prof
}

# ----------------------------------------------------------------------------
# go-check-deps - Check dependencies for issues
# ----------------------------------------------------------------------------
go-check-deps() {
    echo "=== Checking Go dependencies ==="

    echo "Checking for vulnerabilities..."
    govulncheck ./...

    echo -e "\nChecking for outdated dependencies..."
    go list -u -m all | grep '\['

    echo -e "\nDependency graph:"
    goda graph "..." | head -20
    echo "(Showing first 20 lines, run 'goda graph ...' for full output)"
}

# ----------------------------------------------------------------------------
# go-benchmark-compare - Compare benchmark results
#
# Arguments:
#   $1 - Old benchmark file (required)
#   $2 - New benchmark file (required)
#
# Example:
#   go test -bench=. > old.txt
#   # make changes
#   go test -bench=. > new.txt
#   go-benchmark-compare old.txt new.txt
# ----------------------------------------------------------------------------
go-benchmark-compare() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: go-benchmark-compare <old-benchmark> <new-benchmark>"
        return 1
    fi

    echo "Comparing benchmark results..."
    benchstat "$1" "$2"
}

# ----------------------------------------------------------------------------
# go-live - Run with live reload using air
#
# Arguments:
#   $@ - Additional arguments for air
#
# Example:
#   go-live
#   go-live --build.cmd "go build -o ./tmp/main ."
# ----------------------------------------------------------------------------
go-live() {
    if [ ! -f .air.toml ]; then
        echo "Initializing air configuration..."
        air init
    fi

    echo "Starting live reload server..."
    air "$@"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
GOLANG_DEV_BASHRC_EOF

log_command "Setting golang-dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/55-golang-dev.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating golang-dev startup script..."

log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/35-golang-dev-setup.sh << EOF
#!/bin/bash
# Go development tools configuration
if command -v go &> /dev/null; then
    echo "=== Go Development Tools ==="

    # Check for .golangci.yml
    if [ -f ${WORKING_DIR}/.golangci.yml ] || [ -f ${WORKING_DIR}/.golangci.yaml ]; then
        echo "golangci-lint configuration detected"
        echo "Run 'golangci-lint run' to lint your code"
    fi

    # Check for Makefile
    if [ -f ${WORKING_DIR}/Makefile ]; then
        if grep -q "test:" ${WORKING_DIR}/Makefile 2>/dev/null; then
            echo "Makefile with test target detected"
            echo "Run 'make test' to run tests"
        fi
    fi

    # Check for .goreleaser.yml
    if [ -f ${WORKING_DIR}/.goreleaser.yml ] || [ -f ${WORKING_DIR}/.goreleaser.yaml ]; then
        echo "GoReleaser configuration detected"
        echo "Run 'goreleaser check' to validate config"
    fi

    # Show available dev tools
    echo ""
    echo "Go development tools available:"
    echo "  Linting: golangci-lint, staticcheck, gosec, revive, errcheck"
    echo "  Testing: gotests, mockgen, richgo, benchstat"
    echo "  Analysis: go-callvis, goda, govulncheck"
    echo "  Workflow: air (live reload), goreleaser, ko"
    echo ""
    echo "Helpful commands:"
    echo "  go-lint-all         - Run all linters"
    echo "  go-test-coverage    - Generate coverage report"
    echo "  go-generate-tests   - Generate test files"
    echo "  go-visualize        - Visualize code structure"
    echo "  go-live            - Run with live reload"
fi
EOF

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
command cat > /etc/go-dev-templates/.golangci.yml << 'EOF'
linters:
  enable:
    - gofmt
    - golint
    - govet
    - errcheck
    - staticcheck
    - ineffassign
    - goconst
    - gocyclo
    - misspell
    - unparam
    - nakedret
    - prealloc
    - scopelint
    - gocritic
    - gochecknoinits
    - gochecknoglobals
    - gosec

linters-settings:
  gocyclo:
    min-complexity: 15
  goconst:
    min-len: 3
    min-occurrences: 3
  misspell:
    locale: US

issues:
  exclude-rules:
    - path: _test\.go
      linters:
        - gocyclo
        - errcheck
        - gosec
EOF

# Default .air.toml
command cat > /etc/go-dev-templates/.air.toml << 'EOF'
root = "."
testdata_dir = "testdata"
tmp_dir = "tmp"

[build]
  cmd = "go build -o ./tmp/main ."
  bin = "tmp/main"
  full_bin = "./tmp/main"
  include_ext = ["go", "tpl", "tmpl", "html"]
  exclude_dir = ["assets", "tmp", "vendor", "testdata"]
  include_dir = []
  exclude_file = []
  delay = 1000
  stop_on_error = false
  log = "build-errors.log"
  send_interrupt = false
  kill_delay = "0s"

[color]
  main = "magenta"
  watcher = "cyan"
  build = "yellow"
  runner = "green"
  app = ""

[log]
  time = false

[misc]
  clean_on_exit = true
EOF

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating golang-dev verification script..."

command cat > /usr/local/bin/test-golang-dev << 'EOF'
#!/bin/bash
echo "=== Go Development Tools Status ==="

# Check core development tools
echo ""
echo "Core development tools:"
for tool in gopls dlv golangci-lint goimports gomodifytags impl goplay; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check linting tools
echo ""
echo "Linting tools:"
for tool in staticcheck gosec revive errcheck ineffassign gocritic gocyclo gocognit goconst godot; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check testing tools
echo ""
echo "Testing tools:"
for tool in gotests mockgen richgo benchstat govulncheck stress; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check workflow tools
echo ""
echo "Workflow tools:"
for tool in air goreleaser ko swag wire godoc; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check analysis tools
echo ""
echo "Analysis tools:"
for tool in go-callvis goda; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check protobuf tools
echo ""
echo "Protobuf tools:"
for tool in protoc-gen-go protoc-gen-go-grpc; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

echo ""
echo "Run 'go-lint-all' to run all linters"
echo "Run 'go-test-coverage' to generate coverage report"
EOF

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

echo ""
echo "Run 'test-golang-dev' to check installed tools"
echo "Run 'check-build-logs.sh golang-development-tools' to review installation logs"
