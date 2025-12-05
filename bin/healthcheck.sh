#!/bin/bash
# Container Health Check Script
#
# Verifies that the container is properly initialized and key tools are functional.
# Designed to be used as a Docker HEALTHCHECK or for manual verification.
#
# Exit codes:
#   0 - Container is healthy
#   1 - Container is unhealthy
#
# Usage:
#   ./healthcheck.sh                    # Check all features
#   ./healthcheck.sh --quick            # Quick check (essential only)
#   ./healthcheck.sh --verbose          # Detailed output
#   ./healthcheck.sh --feature python   # Check specific feature

set -euo pipefail

# Configuration
QUICK_MODE=false
VERBOSE=false
SPECIFIC_FEATURE=""
EXIT_CODE=0
CUSTOM_CHECKS_DIR="${HEALTHCHECK_CUSTOM_DIR:-/etc/healthcheck.d}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --feature)
            SPECIFIC_FEATURE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--quick] [--verbose] [--feature NAME]"
            echo ""
            echo "Options:"
            echo "  --quick           Core checks only (fast)"
            echo "  --verbose         Detailed output"
            echo "  --feature NAME    Check specific feature"
            echo ""
            echo "Features: core, python, node, rust, go, ruby, r, java, docker, kubernetes, custom"
            echo ""
            echo "Custom checks:"
            echo "  Place executable scripts in $CUSTOM_CHECKS_DIR"
            echo "  Scripts run in sorted order (use 10-foo.sh, 20-bar.sh naming)"
            echo "  Override directory with HEALTHCHECK_CUSTOM_DIR environment variable"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--quick] [--verbose] [--feature NAME]"
            exit 1
            ;;
    esac
done

# Logging functions
log_check() {
    if [ "$VERBOSE" = "true" ]; then
        echo "[CHECK] $1"
    fi
}

log_pass() {
    if [ "$VERBOSE" = "true" ]; then
        echo "[✓] $1"
    fi
}

log_fail() {
    echo "[✗] $1" >&2
    EXIT_CODE=1
}

log_warn() {
    if [ "$VERBOSE" = "true" ]; then
        echo "[⚠] $1"
    fi
}

# Core health checks (always run)
check_core() {
    log_check "Checking core container health..."

    # Check if container is initialized
    USERNAME=$(getent passwd 1000 | cut -d: -f1 || echo "")
    if [ -z "$USERNAME" ]; then
        log_fail "No user with UID 1000 found"
        return 1
    fi
    log_pass "Container user: $USERNAME"

    # Check if first-time setup completed
    if [ -f "/home/${USERNAME}/.container-initialized" ]; then
        log_pass "Container initialized"
    else
        log_warn "Container not yet initialized (first boot pending)"
    fi

    # Check essential directories exist
    for dir in /workspace /cache /etc/container; do
        if [ -d "$dir" ]; then
            log_pass "Directory exists: $dir"
        else
            log_fail "Missing directory: $dir"
        fi
    done

    # Check basic commands
    for cmd in bash sh; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_pass "Command available: $cmd"
        else
            log_fail "Missing command: $cmd"
        fi
    done
}

# Feature-specific health checks
check_python() {
    log_check "Checking Python..."

    if command -v python3 >/dev/null 2>&1; then
        VERSION=$(python3 --version 2>&1 | awk '{print $2}')
        log_pass "Python installed: $VERSION"

        # Check pip
        if command -v pip3 >/dev/null 2>&1; then
            log_pass "pip available"
        else
            log_warn "pip not found"
        fi

        # Check cache directory
        if [ -d "/cache/pip" ]; then
            log_pass "Python cache configured"
        fi
    else
        log_fail "Python not installed"
    fi
}

check_node() {
    log_check "Checking Node.js..."

    if command -v node >/dev/null 2>&1; then
        VERSION=$(node --version)
        log_pass "Node.js installed: $VERSION"

        # Check npm
        if command -v npm >/dev/null 2>&1; then
            log_pass "npm available"
        else
            log_warn "npm not found"
        fi

        # Check cache directory
        if [ -d "/cache/npm" ]; then
            log_pass "Node cache configured"
        fi
    else
        log_fail "Node.js not installed"
    fi
}

check_rust() {
    log_check "Checking Rust..."

    if command -v rustc >/dev/null 2>&1; then
        VERSION=$(rustc --version | awk '{print $2}')
        log_pass "Rust installed: $VERSION"

        # Check cargo
        if command -v cargo >/dev/null 2>&1; then
            log_pass "Cargo available"
        else
            log_warn "Cargo not found"
        fi

        # Check cache directory
        if [ -d "/cache/cargo" ]; then
            log_pass "Rust cache configured"
        fi
    else
        log_fail "Rust not installed"
    fi
}

check_golang() {
    log_check "Checking Go..."

    if command -v go >/dev/null 2>&1; then
        VERSION=$(go version | awk '{print $3}')
        log_pass "Go installed: $VERSION"

        # Check cache directories
        if [ -d "/cache/go" ]; then
            log_pass "Go cache configured"
        fi
    else
        log_fail "Go not installed"
    fi
}

check_ruby() {
    log_check "Checking Ruby..."

    if command -v ruby >/dev/null 2>&1; then
        VERSION=$(ruby --version | awk '{print $2}')
        log_pass "Ruby installed: $VERSION"

        # Check gem
        if command -v gem >/dev/null 2>&1; then
            log_pass "RubyGems available"
        else
            log_warn "RubyGems not found"
        fi

        # Check cache directory
        if [ -d "/cache/bundle" ]; then
            log_pass "Ruby cache configured"
        fi
    else
        log_fail "Ruby not installed"
    fi
}

check_r() {
    log_check "Checking R..."

    if command -v R >/dev/null 2>&1; then
        VERSION=$(R --version 2>&1 | head -1 | awk '{print $3}')
        log_pass "R installed: $VERSION"

        # Check Rscript
        if command -v Rscript >/dev/null 2>&1; then
            log_pass "Rscript available"
        else
            log_warn "Rscript not found"
        fi

        # Check cache directory
        if [ -d "/cache/r" ]; then
            log_pass "R cache configured"
        fi
    else
        log_fail "R not installed"
    fi
}

check_java() {
    log_check "Checking Java..."

    if command -v java >/dev/null 2>&1; then
        VERSION=$(java -version 2>&1 | head -1 | awk -F '"' '{print $2}')
        log_pass "Java installed: $VERSION"

        # Check cache directory
        if [ -d "/cache/maven" ] || [ -d "/cache/gradle" ]; then
            log_pass "Java build tool cache configured"
        fi
    else
        log_fail "Java not installed"
    fi
}

check_docker() {
    log_check "Checking Docker..."

    if command -v docker >/dev/null 2>&1; then
        log_pass "Docker CLI available"

        # Try to connect to Docker daemon (may not be available in healthcheck)
        if docker info >/dev/null 2>&1; then
            log_pass "Docker daemon accessible"
        else
            log_warn "Docker daemon not accessible (may be expected)"
        fi
    else
        log_fail "Docker not installed"
    fi
}

check_kubernetes() {
    log_check "Checking Kubernetes tools..."

    FOUND=false
    if command -v kubectl >/dev/null 2>&1; then
        VERSION=$(kubectl version --client --short 2>/dev/null | awk '{print $3}' || echo "unknown")
        log_pass "kubectl available: $VERSION"
        FOUND=true
    fi

    if command -v helm >/dev/null 2>&1; then
        log_pass "Helm available"
        FOUND=true
    fi

    if [ "$FOUND" = "false" ]; then
        log_fail "No Kubernetes tools installed"
    fi
}

# Run custom health checks from directory
run_custom_checks() {
    if [ ! -d "$CUSTOM_CHECKS_DIR" ]; then
        log_check "No custom checks directory: $CUSTOM_CHECKS_DIR"
        return 0
    fi

    # Check if there are any executable files
    local has_checks=false
    for check in "$CUSTOM_CHECKS_DIR"/*; do
        if [ -x "$check" ] && [ -f "$check" ]; then
            has_checks=true
            break
        fi
    done

    if [ "$has_checks" = "false" ]; then
        log_check "No custom checks found in $CUSTOM_CHECKS_DIR"
        return 0
    fi

    log_check "Running custom health checks..."

    # Run checks in sorted order (allows 10-foo.sh, 20-bar.sh ordering)
    for check in "$CUSTOM_CHECKS_DIR"/*; do
        if [ -x "$check" ] && [ -f "$check" ]; then
            local check_name
            check_name=$(basename "$check")
            log_check "Running custom check: $check_name"

            if "$check"; then
                log_pass "Custom check passed: $check_name"
            else
                log_fail "Custom check failed: $check_name"
            fi
        fi
    done
}

# Auto-detect installed features and run checks
auto_detect_features() {
    log_check "Auto-detecting installed features..."

    # Core is always checked
    check_core

    # Only check features that are installed
    if command -v python3 >/dev/null 2>&1; then check_python || true; fi
    if command -v node >/dev/null 2>&1; then check_node || true; fi
    if command -v rustc >/dev/null 2>&1; then check_rust || true; fi
    if command -v go >/dev/null 2>&1; then check_golang || true; fi
    if command -v ruby >/dev/null 2>&1; then check_ruby || true; fi
    if command -v R >/dev/null 2>&1; then check_r || true; fi
    if command -v java >/dev/null 2>&1; then check_java || true; fi
    if command -v docker >/dev/null 2>&1; then check_docker || true; fi
    if command -v kubectl >/dev/null 2>&1; then check_kubernetes || true; fi

    # Run custom checks if any exist
    run_custom_checks
}

# Main execution
if [ -n "$SPECIFIC_FEATURE" ]; then
    # Check specific feature
    case "$SPECIFIC_FEATURE" in
        core) check_core ;;
        python) check_python ;;
        node) check_node ;;
        rust) check_rust ;;
        go|golang) check_golang ;;
        ruby) check_ruby ;;
        r) check_r ;;
        java) check_java ;;
        docker) check_docker ;;
        kubernetes|k8s) check_kubernetes ;;
        custom) run_custom_checks ;;
        *)
            echo "Unknown feature: $SPECIFIC_FEATURE"
            echo "Available: core, python, node, rust, go, ruby, r, java, docker, kubernetes, custom"
            exit 1
            ;;
    esac
elif [ "$QUICK_MODE" = "true" ]; then
    # Quick mode: only core checks
    check_core
else
    # Full check: auto-detect and check all installed features
    auto_detect_features
fi

# Exit with appropriate code
if [ "$EXIT_CODE" -eq 0 ]; then
    if [ "$VERBOSE" = "true" ]; then
        echo "✓ Container is healthy"
    fi
    exit 0
else
    echo "✗ Container health check failed" >&2
    exit 1
fi
