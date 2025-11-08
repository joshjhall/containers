#!/bin/bash
# Go Programming Language - Compiler, runtime, and development tools
#
# Description:
#   Installs the Go programming language with common development tools.
#   Configures workspace and cache directories for optimal container usage.
#
# Features:
#   - Go compiler and runtime
#   - Basic Go tools (gofmt, go vet, etc.)
#   - Module support
#   - Proper cache directory configuration
#
# Cache Strategy:
#   - If /cache directory exists and GOPATH isn't set, uses /cache/go
#   - Otherwise uses standard home directory location ~/go
#   - This allows volume mounting for persistent module cache across container rebuilds
#
# Environment Variables:
#   - GO_VERSION: Go version to install
#   - GOPATH: Go workspace directory (default: /cache/go or ~/go)
#   - GOCACHE: Go build cache (default: within GOPATH)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Source checksum fetching utilities
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# ============================================================================
# Version Configuration
# ============================================================================
# Go version to install
GO_VERSION="${GO_VERSION:-1.25.3}"

# Extract major.minor version for comparison
GO_MAJOR=$(echo $GO_VERSION | cut -d. -f1)
GO_MINOR=$(echo $GO_VERSION | cut -d. -f2)

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

cd /tmp

# Fetch checksum dynamically from go.dev
log_message "Fetching checksum for Go ${GO_VERSION} ${GO_ARCH}..."

if ! GO_CHECKSUM=$(fetch_go_checksum "${GO_VERSION}" "${GO_ARCH}" 2>/dev/null); then
    log_error "Failed to fetch checksum for Go ${GO_VERSION} ${GO_ARCH} from go.dev"
    log_error ""
    log_error "This could mean:"
    log_error "  - go.dev is unreachable (network issue)"
    log_error "  - Go ${GO_VERSION} does not exist or is not published yet"
    log_error "  - The download page format has changed"
    log_error ""
    log_error "Please verify:"
    log_error "  1. Network connectivity: curl -I https://go.dev/dl/"
    log_error "  2. Version exists: https://go.dev/dl/#go${GO_VERSION}"
    log_feature_end
    exit 1
fi

log_message "✓ Fetched checksum from go.dev"

# Validate checksum format
if ! validate_checksum_format "$GO_CHECKSUM" "sha256"; then
    log_error "Invalid checksum format for Go ${GO_VERSION}: ${GO_CHECKSUM}"
    log_feature_end
    exit 1
fi

# Download and extract Go tarball with checksum verification
log_message "Downloading and verifying Go ${GO_VERSION} for ${GO_ARCH}..."
log_message "Using checksum: ${GO_CHECKSUM}"
download_and_extract \
    "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" \
    "${GO_CHECKSUM}" \
    "/usr/local" \
    ""  # Extract all files (creates /usr/local/go/)

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
log_command "Creating Go directories" \
    mkdir -p "${GOPATH}"/{bin,src,pkg} "${GOCACHE}" "${GOMODCACHE}"

log_command "Setting cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${GOPATH}" "${GOCACHE}" "${GOMODCACHE}"

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

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Go environment variables
export GOROOT=/usr/local/go
export GOPATH="/cache/go"
export GOCACHE="/cache/go-build"
export GOMODCACHE="/cache/go-mod"
export PATH="/usr/local/go/bin:${GOPATH}/bin:$PATH"

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
# go-new - Create a new Go module project
#
# Arguments:
#   $1 - Module name (required, e.g., github.com/user/project)
#   $2 - Project type (optional: cli, lib, api, default: lib)
#
# Example:
#   go-new github.com/myuser/myproject cli
# ----------------------------------------------------------------------------
go-new() {
    if [ -z "$1" ]; then
        echo "Usage: go-new <module-name> [type]"
        echo "Types: cli, lib, api"
        return 1
    fi

    local module_name="$1"
    local project_type="${2:-lib}"
    local project_dir=$(basename "$module_name")

    echo "Creating new Go project: $module_name (type: $project_type)"

    # Create project directory
    mkdir -p "$project_dir"
    cd "$project_dir"

    # Initialize go module
    go mod init "$module_name"

    # Create standard Go project structure
    mkdir -p cmd pkg internal test docs

    # Create .gitignore
    cat > .gitignore << 'GITIGNORE'
# Binaries
*.exe
*.dll
*.so
*.dylib

# Test binary, built with `go test -c`
*.test

# Output of the go coverage tool
*.out

# Dependency directories
vendor/

# Go workspace file
go.work

# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db
GITIGNORE

    # Create type-specific files
    case "$project_type" in
        cli)
            mkdir -p cmd/${project_dir}
            cat > cmd/${project_dir}/main.go << 'CLIMAIN'
package main

import (
    "flag"
    "fmt"
    "os"
)

var version = "dev"

func main() {
    var showVersion bool
    flag.BoolVar(&showVersion, "version", false, "Show version")
    flag.Parse()

    if showVersion {
        fmt.Printf("%s version %s\n", os.Args[0], version)
        os.Exit(0)
    }

    fmt.Println("Hello from CLI!")
}
CLIMAIN
            ;;
        api)
            cat > main.go << 'APIMAIN'
package main

import (
    "encoding/json"
    "log"
    "net/http"
    "os"
)

type Response struct {
    Message string `json:"message"`
    Status  string `json:"status"`
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(Response{
        Message: "API is healthy",
        Status:  "ok",
    })
}

func main() {
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }

    http.HandleFunc("/health", healthHandler)

    log.Printf("Server starting on port %s", port)
    if err := http.ListenAndServe(":"+port, nil); err != nil {
        log.Fatal(err)
    }
}
APImain
            ;;
        *)
            # Default library setup
            cat > ${project_dir}.go << LIBMAIN
package ${project_dir}

// Hello returns a greeting message
func Hello(name string) string {
    return "Hello, " + name + "!"
}
LIBMAIN

            cat > ${project_dir}_test.go << LIBTEST
package ${project_dir}

import "testing"

func TestHello(t *testing.T) {
    got := Hello("World")
    want := "Hello, World!"

    if got != want {
        t.Errorf("Hello() = %q, want %q", got, want)
    }
}
LIBTEST
            ;;
    esac

    # Create Makefile
    cat > Makefile << 'MAKEFILE'
.PHONY: build test lint clean

build:
	go build -v ./...

test:
	go test -v -race -coverprofile=coverage.out ./...

lint:
	go vet ./...

clean:
	go clean
	rm -f coverage.out

run:
	go run .
MAKEFILE

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

cat > /etc/container/first-startup/30-go-setup.sh << 'EOF'
#!/bin/bash
# Go development environment setup

# Set up Go environment
export GOPATH="/cache/go"
export GOCACHE="/cache/go-build"
export GOMODCACHE="/cache/go-mod"
export PATH="/usr/local/go/bin:${GOPATH}/bin:$PATH"

# Check for Go projects
if [ -f ${WORKING_DIR}/go.mod ]; then
    echo "=== Go Project Detected ==="
    echo "Go $(go version | awk '{print $3}') is installed"
    echo "GOPATH: ${GOPATH}"
    echo "Module: $(head -1 ${WORKING_DIR}/go.mod | awk '{print $2}')"

    cd ${WORKING_DIR}

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
    echo "  go-new <module-name> [cli|lib|api]"
fi
EOF

log_command "Setting startup script permissions" \
    chmod +x /etc/container/first-startup/30-go-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Go verification script..."

cat > /usr/local/bin/test-go << 'EOF'
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
