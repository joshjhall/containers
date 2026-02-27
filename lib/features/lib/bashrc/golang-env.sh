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
