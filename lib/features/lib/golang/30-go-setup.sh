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
    echo "Go $(go version | command awk '{print $3}') is installed"
    echo "GOPATH: ${GOPATH}"
    echo "Module: $(command head -1 "${WORKING_DIR}/go.mod" | command awk '{print $2}')"

    cd "${WORKING_DIR}" || return

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
