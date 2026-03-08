#!/bin/bash
# Unit tests for lib/base/sigstore-verify.sh
# Tests rejection paths, error handling, and fallback behavior

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Sigstore Verification Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/sigstore-verify.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-sigstore-verify-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Function Export Verification
# ============================================================================

test_exports_verify_sigstore_signature() {
    assert_file_contains "$SOURCE_FILE" "export -f verify_sigstore_signature" \
        "verify_sigstore_signature is exported"
}

test_exports_download_and_verify_sigstore() {
    assert_file_contains "$SOURCE_FILE" "export -f download_and_verify_sigstore" \
        "download_and_verify_sigstore is exported"
}

test_exports_download_and_verify_kubectl_sigstore() {
    assert_file_contains "$SOURCE_FILE" "export -f download_and_verify_kubectl_sigstore" \
        "download_and_verify_kubectl_sigstore is exported"
}

test_exports_get_python_release_manager() {
    assert_file_contains "$SOURCE_FILE" "export -f get_python_release_manager" \
        "get_python_release_manager is exported"
}

# ============================================================================
# verify_sigstore_signature - Rejection Paths
# ============================================================================

# Test: returns 1 when cosign is not installed
test_verify_sigstore_cosign_not_installed() {
    local exit_code=0
    bash -c "
        _SIGSTORE_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        # Ensure cosign is not found
        cosign() { return 127; }
        export -f cosign
        # Override command -v to report cosign missing
        command() {
            if [ \"\$1\" = '-v' ] && [ \"\$2\" = 'cosign' ]; then
                return 1
            fi
            builtin command \"\$@\"
        }
        verify_sigstore_signature '/tmp/nonexistent' '/tmp/nonexistent.sig' \
            'user@example.org' 'https://accounts.google.com' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_sigstore_signature returns 1 when cosign not installed"
}

# Test: returns 1 when target file doesn't exist
test_verify_sigstore_missing_target_file() {
    local exit_code=0
    bash -c "
        _SIGSTORE_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        # Provide a fake cosign so the check passes
        cosign() { return 0; }
        command() {
            if [ \"\$1\" = '-v' ] && [ \"\$2\" = 'cosign' ]; then
                return 0
            fi
            builtin command \"\$@\"
        }
        verify_sigstore_signature '$TEST_TEMP_DIR/no-such-file.tar.gz' \
            '$TEST_TEMP_DIR/no-such-file.tar.gz.sig' \
            'user@example.org' 'https://accounts.google.com' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_sigstore_signature returns 1 when target file missing"
}

# Test: returns 1 when signature file doesn't exist
test_verify_sigstore_missing_sig_file() {
    # Create a target file but no signature
    echo "test content" > "$TEST_TEMP_DIR/testfile.tar.gz"

    local exit_code=0
    bash -c "
        _SIGSTORE_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        cosign() { return 0; }
        command() {
            if [ \"\$1\" = '-v' ] && [ \"\$2\" = 'cosign' ]; then
                return 0
            fi
            builtin command \"\$@\"
        }
        verify_sigstore_signature '$TEST_TEMP_DIR/testfile.tar.gz' \
            '$TEST_TEMP_DIR/testfile.tar.gz.sig' \
            'user@example.org' 'https://accounts.google.com' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_sigstore_signature returns 1 when sig file missing"
}

# Test: returns 1 when cert file specified but doesn't exist
test_verify_sigstore_missing_cert_file() {
    # Create target and sig files but no cert
    echo "test content" > "$TEST_TEMP_DIR/testfile.tar.gz"
    echo "fake sig" > "$TEST_TEMP_DIR/testfile.tar.gz.sig"

    local exit_code=0
    bash -c "
        _SIGSTORE_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        cosign() { return 0; }
        command() {
            if [ \"\$1\" = '-v' ] && [ \"\$2\" = 'cosign' ]; then
                return 0
            fi
            builtin command \"\$@\"
        }
        verify_sigstore_signature '$TEST_TEMP_DIR/testfile.tar.gz' \
            '$TEST_TEMP_DIR/testfile.tar.gz.sig' \
            'user@example.org' 'https://accounts.google.com' \
            '$TEST_TEMP_DIR/testfile.tar.gz.crt' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_sigstore_signature returns 1 when cert file missing"
}

# ============================================================================
# download_and_verify_kubectl_sigstore - Rejection Paths
# ============================================================================

# Test: returns 1 when cosign is not installed
test_kubectl_sigstore_cosign_not_installed() {
    local exit_code=0
    bash -c "
        _SIGSTORE_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        # Hide cosign
        hash -r 2>/dev/null
        unset -f cosign 2>/dev/null || true
        # Ensure cosign binary not on PATH
        export PATH='/usr/bin:/bin'
        download_and_verify_kubectl_sigstore '/tmp/kubectl' '1.28.0' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_kubectl_sigstore returns 1 when cosign missing"
}

# ============================================================================
# download_and_verify_sigstore - Error Paths
# ============================================================================

# Test: returns 1 when curl fails to download signature
test_download_and_verify_sigstore_curl_failure() {
    # Create a target file
    echo "test content" > "$TEST_TEMP_DIR/testfile.tar.gz"

    local exit_code=0
    bash -c "
        _SIGSTORE_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        # Mock curl to fail
        curl() { return 1; }
        export -f curl
        download_and_verify_sigstore '$TEST_TEMP_DIR/testfile.tar.gz' \
            'https://example.com/testfile.tar.gz.sigstore' \
            'user@example.org' 'https://accounts.google.com' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_sigstore returns 1 when curl fails"
}

# ============================================================================
# get_python_release_manager - Additional Mappings
# ============================================================================

# Source for direct testing of get_python_release_manager
source "$PROJECT_ROOT/lib/base/logging.sh" 2>/dev/null || true
source "$PROJECT_ROOT/lib/base/sigstore-verify.sh" 2>/dev/null || true

# Test: Python 3.7 release manager (nad@python.org)
test_python_3_7_release_manager() {
    local output
    output=$(get_python_release_manager "3.7.17")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "nad@python.org" "$cert_identity" "Python 3.7 certificate identity"
    assert_equals "https://github.com/login/oauth" "$oidc_issuer" "Python 3.7 OIDC issuer"
}

# Test: Python 3.15 release manager (hugo@python.org)
test_python_3_15_release_manager() {
    local output
    output=$(get_python_release_manager "3.15.0")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "hugo@python.org" "$cert_identity" "Python 3.15 certificate identity"
    assert_equals "https://github.com/login/oauth" "$oidc_issuer" "Python 3.15 OIDC issuer"
}

# Test: Python 3.16 release manager (savannah@python.org)
test_python_3_16_release_manager() {
    local output
    output=$(get_python_release_manager "3.16.0")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "savannah@python.org" "$cert_identity" "Python 3.16 certificate identity"
    assert_equals "https://github.com/login/oauth" "$oidc_issuer" "Python 3.16 OIDC issuer"
}

# Test: Python 3.17 release manager (savannah@python.org)
test_python_3_17_release_manager() {
    local output
    output=$(get_python_release_manager "3.17.0")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "savannah@python.org" "$cert_identity" "Python 3.17 certificate identity"
    assert_equals "https://github.com/login/oauth" "$oidc_issuer" "Python 3.17 OIDC issuer"
}

# ============================================================================
# Run all tests
# ============================================================================

# Export verification
run_test test_exports_verify_sigstore_signature "Exports verify_sigstore_signature"
run_test test_exports_download_and_verify_sigstore "Exports download_and_verify_sigstore"
run_test test_exports_download_and_verify_kubectl_sigstore "Exports download_and_verify_kubectl_sigstore"
run_test test_exports_get_python_release_manager "Exports get_python_release_manager"

# verify_sigstore_signature rejection paths
run_test_with_setup test_verify_sigstore_cosign_not_installed "verify_sigstore_signature: cosign not installed"
run_test_with_setup test_verify_sigstore_missing_target_file "verify_sigstore_signature: target file missing"
run_test_with_setup test_verify_sigstore_missing_sig_file "verify_sigstore_signature: sig file missing"
run_test_with_setup test_verify_sigstore_missing_cert_file "verify_sigstore_signature: cert file missing"

# download_and_verify_kubectl_sigstore rejection paths
run_test_with_setup test_kubectl_sigstore_cosign_not_installed "kubectl_sigstore: cosign not installed"

# download_and_verify_sigstore error paths
run_test_with_setup test_download_and_verify_sigstore_curl_failure "download_and_verify_sigstore: curl failure"

# get_python_release_manager additional mappings
run_test test_python_3_7_release_manager "Python 3.7 release manager (nad)"
run_test test_python_3_15_release_manager "Python 3.15 release manager (hugo)"
run_test test_python_3_16_release_manager "Python 3.16 release manager (savannah)"
run_test test_python_3_17_release_manager "Python 3.17 release manager (savannah)"

# Generate test report
generate_report
