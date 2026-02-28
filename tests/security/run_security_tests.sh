#!/bin/bash
# Security Regression Test Suite
#
# Runs security tests against built container images to verify:
# - Non-root user configuration
# - File permissions
# - Capability restrictions
# - Network security
# - Secret protection
#
# Usage:
#   ./tests/security/run_security_tests.sh [image_name]
#
# If no image is specified, builds a test image first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$PROJECT_ROOT/tests/results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Default test image
TEST_IMAGE="${1:-}"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "  ${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

log_test_fail() {
    echo -e "  ${RED}✗${NC} $1"
    ((TESTS_FAILED++))
}

log_test_skip() {
    echo -e "  ${YELLOW}○${NC} $1 (skipped)"
    ((TESTS_SKIPPED++))
}

# Build test image if not provided
build_test_image() {
    log_info "Building test image..."
    TEST_IMAGE="security-test:$(date +%s)"

    docker build \
        -f "$PROJECT_ROOT/Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=security-test \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        -t "$TEST_IMAGE" \
        "$PROJECT_ROOT" > /dev/null 2>&1

    log_info "Built test image: $TEST_IMAGE"
}

# Cleanup function
# shellcheck disable=SC2317  # Function is used by trap
cleanup() {
    if [[ "$TEST_IMAGE" == security-test:* ]]; then
        log_info "Cleaning up test image..."
        docker rmi "$TEST_IMAGE" > /dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

# =============================================================================
# Test Functions
# =============================================================================

test_non_root_user() {
    echo ""
    log_info "Testing non-root user configuration..."

    # Test 1: Container runs as non-root
    local user_id
    user_id=$(docker run --rm "$TEST_IMAGE" id -u 2>/dev/null)
    if [[ "$user_id" != "0" ]]; then
        log_test "Container runs as non-root user (uid=$user_id)"
    else
        log_test_fail "Container runs as root (uid=0)"
    fi

    # Test 2: User has no passwordless sudo by default
    if docker run --rm "$TEST_IMAGE" sudo -n true 2>/dev/null; then
        log_test_fail "Passwordless sudo is enabled"
    else
        log_test "Passwordless sudo is disabled"
    fi

    # Test 3: Home directory ownership
    local home_owner
    home_owner=$(docker run --rm "$TEST_IMAGE" stat -c '%U' /home/developer 2>/dev/null || echo "unknown")
    if [[ "$home_owner" == "developer" ]]; then
        log_test "Home directory owned by developer user"
    else
        log_test_fail "Home directory not owned by developer (owner=$home_owner)"
    fi
}

test_file_permissions() {
    echo ""
    log_info "Testing file permissions..."

    # Test 1: No world-writable files in /usr
    local world_writable
    world_writable=$(docker run --rm "$TEST_IMAGE" find /usr -type f -perm -0002 2>/dev/null | command wc -l)
    if [[ "$world_writable" -eq 0 ]]; then
        log_test "No world-writable files in /usr"
    else
        log_test_fail "Found $world_writable world-writable files in /usr"
    fi

    # Test 2: Sensitive files have proper permissions
    local passwd_perms
    passwd_perms=$(docker run --rm "$TEST_IMAGE" stat -c '%a' /etc/passwd 2>/dev/null)
    if [[ "$passwd_perms" == "644" ]]; then
        log_test "/etc/passwd has correct permissions (644)"
    else
        log_test_fail "/etc/passwd has incorrect permissions ($passwd_perms)"
    fi

    # Test 3: Shadow file is not world-readable
    local shadow_perms
    shadow_perms=$(docker run --rm "$TEST_IMAGE" stat -c '%a' /etc/shadow 2>/dev/null || echo "000")
    if [[ ! "$shadow_perms" =~ [4567]$ ]]; then
        log_test "/etc/shadow is not world-readable"
    else
        log_test_fail "/etc/shadow is world-readable ($shadow_perms)"
    fi
}

test_capabilities() {
    echo ""
    log_info "Testing Linux capabilities..."

    # Test 1: Check if capsh is available
    if ! docker run --rm "$TEST_IMAGE" which capsh > /dev/null 2>&1; then
        log_test_skip "capsh not available for capability testing"
        return
    fi

    # Test 2: No dangerous capabilities by default
    local caps
    caps=$(docker run --rm "$TEST_IMAGE" capsh --print 2>/dev/null || echo "")

    if [[ -z "$caps" ]]; then
        log_test_skip "Could not retrieve capability information"
        return
    fi

    # Check for dangerous capabilities
    local dangerous_caps=("cap_sys_admin" "cap_sys_ptrace" "cap_net_admin")
    local has_dangerous=false

    for cap in "${dangerous_caps[@]}"; do
        if echo "$caps" | command grep -qi "$cap"; then
            has_dangerous=true
            log_test_fail "Container has dangerous capability: $cap"
        fi
    done

    if [[ "$has_dangerous" == "false" ]]; then
        log_test "No dangerous capabilities present"
    fi
}

test_network_security() {
    echo ""
    log_info "Testing network security..."

    # Test 1: No listening services by default
    local listening
    listening=$(docker run --rm "$TEST_IMAGE" sh -c "netstat -tlnp 2>/dev/null || ss -tlnp 2>/dev/null" | command grep -c LISTEN || echo "0")
    if [[ "$listening" -eq 0 ]]; then
        log_test "No listening services in container"
    else
        log_test_fail "Container has $listening listening services"
    fi

    # Test 2: curl uses HTTPS by default (check CA certificates)
    if docker run --rm "$TEST_IMAGE" test -f /etc/ssl/certs/ca-certificates.crt; then
        log_test "CA certificates are installed"
    else
        log_test_fail "CA certificates are not installed"
    fi
}

test_secret_protection() {
    echo ""
    log_info "Testing secret protection..."

    # Test 1: No secrets in environment variables
    local env_secrets
    env_secrets=$(docker run --rm "$TEST_IMAGE" env 2>/dev/null | command grep -iE '(password|secret|key|token|api_key)=' | command grep -v '^#' || echo "")
    if [[ -z "$env_secrets" ]]; then
        log_test "No secrets in environment variables"
    else
        log_test_fail "Found potential secrets in environment variables"
    fi

    # Test 2: No .env files with secrets
    local env_files
    env_files=$(docker run --rm "$TEST_IMAGE" find /home -name ".env*" -type f 2>/dev/null | command wc -l)
    if [[ "$env_files" -eq 0 ]]; then
        log_test "No .env files in home directory"
    else
        log_test_fail "Found $env_files .env files in home directory"
    fi

    # Test 3: SSH directory permissions (if exists)
    if docker run --rm "$TEST_IMAGE" test -d /home/developer/.ssh 2>/dev/null; then
        local ssh_perms
        ssh_perms=$(docker run --rm "$TEST_IMAGE" stat -c '%a' /home/developer/.ssh 2>/dev/null)
        if [[ "$ssh_perms" == "700" ]]; then
            log_test ".ssh directory has correct permissions (700)"
        else
            log_test_fail ".ssh directory has incorrect permissions ($ssh_perms)"
        fi
    else
        log_test "No .ssh directory present (expected)"
    fi
}

test_image_security() {
    echo ""
    log_info "Testing image security..."

    # Test 1: Image has labels
    local has_labels
    has_labels=$(docker inspect "$TEST_IMAGE" --format '{{range $k, $v := .Config.Labels}}{{$k}}{{end}}' 2>/dev/null)
    if [[ -n "$has_labels" ]]; then
        log_test "Image has metadata labels"
    else
        log_test_fail "Image has no metadata labels"
    fi

    # Test 2: Image doesn't expose dangerous ports
    local exposed_ports
    exposed_ports=$(docker inspect "$TEST_IMAGE" --format '{{range $p, $conf := .Config.ExposedPorts}}{{$p}} {{end}}' 2>/dev/null)
    if [[ -z "$exposed_ports" ]]; then
        log_test "No ports exposed by default"
    else
        log_warn "Image exposes ports: $exposed_ports"
        log_test "Ports exposed (review if necessary): $exposed_ports"
    fi

    # Test 3: Healthcheck is configured
    local healthcheck
    healthcheck=$(docker inspect "$TEST_IMAGE" --format '{{.Config.Healthcheck}}' 2>/dev/null)
    if [[ -n "$healthcheck" && "$healthcheck" != "<nil>" ]]; then
        log_test "Healthcheck is configured"
    else
        log_test_skip "No healthcheck configured (optional)"
    fi
}

test_build_security() {
    echo ""
    log_info "Testing build security practices..."

    # Test 1: No package manager cache
    local apt_cache
    apt_cache=$(docker run --rm "$TEST_IMAGE" sh -c "du -s /var/lib/apt/lists 2>/dev/null || echo '0'" | command awk '{print $1}')
    if [[ "$apt_cache" -lt 1000 ]]; then
        log_test "APT cache is cleaned"
    else
        log_test_fail "APT cache is not cleaned (${apt_cache}KB)"
    fi

    # Test 2: No temporary build files
    local tmp_files
    tmp_files=$(docker run --rm "$TEST_IMAGE" find /tmp -type f 2>/dev/null | command wc -l)
    if [[ "$tmp_files" -lt 5 ]]; then
        log_test "Minimal temporary files in /tmp"
    else
        log_test_fail "Found $tmp_files files in /tmp"
    fi

    # Test 3: Build scripts are cleaned up
    if docker run --rm "$TEST_IMAGE" test -d /tmp/build-scripts 2>/dev/null; then
        log_test_fail "Build scripts not cleaned up (/tmp/build-scripts exists)"
    else
        log_test "Build scripts cleaned up"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "============================================="
    echo "  Security Regression Test Suite"
    echo "============================================="
    echo ""

    # Build or use provided image
    if [[ -z "$TEST_IMAGE" ]]; then
        build_test_image
    else
        log_info "Using provided image: $TEST_IMAGE"
    fi

    # Run all tests
    test_non_root_user
    test_file_permissions
    test_capabilities
    test_network_security
    test_secret_protection
    test_image_security
    test_build_security

    # Summary
    echo ""
    echo "============================================="
    echo "  Test Summary"
    echo "============================================="
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
    echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
    echo ""

    # Write results to file for CI artifact upload
    mkdir -p "$RESULTS_DIR"
    {
        echo "Security Regression Test Results"
        echo "================================"
        echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Image: ${TEST_IMAGE:-built locally}"
        echo ""
        echo "Passed:  $TESTS_PASSED"
        echo "Failed:  $TESTS_FAILED"
        echo "Skipped: $TESTS_SKIPPED"
        echo ""
        if [[ "$TESTS_FAILED" -gt 0 ]]; then
            echo "Result: FAIL"
        else
            echo "Result: PASS"
        fi
    } > "$RESULTS_DIR/security-test-results.txt"

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        log_error "Security tests failed!"
        exit 1
    else
        log_info "All security tests passed!"
        exit 0
    fi
}

main "$@"
