#!/bin/bash
# Unit tests for lib/base/signature-verify.sh
# Tests signature verification functionality including Sigstore and GPG

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Source the script under test
source "$PROJECT_ROOT/lib/base/logging.sh"
source "$PROJECT_ROOT/lib/base/signature-verify.sh"

# Test suite
test_suite "Signature Verification Tests"

# Test: get_python_release_manager function exists
test_get_python_release_manager_exists() {
    if command -v get_python_release_manager >/dev/null 2>&1; then
        assert_true true "get_python_release_manager function exists"
    else
        assert_true false "get_python_release_manager function not found"
    fi
}

# Test: Python 3.11 release manager (pablogsal@python.org)
test_python_3_11_release_manager() {
    local output
    output=$(get_python_release_manager "3.11.0")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "pablogsal@python.org" "$cert_identity" "Python 3.11 certificate identity"
    assert_equals "https://accounts.google.com" "$oidc_issuer" "Python 3.11 OIDC issuer"
}

# Test: Python 3.12 release manager (thomas@python.org)
test_python_3_12_release_manager() {
    local output
    output=$(get_python_release_manager "3.12.5")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "thomas@python.org" "$cert_identity" "Python 3.12 certificate identity"
    assert_equals "https://accounts.google.com" "$oidc_issuer" "Python 3.12 OIDC issuer"
}

# Test: Python 3.13 release manager (thomas@python.org)
test_python_3_13_release_manager() {
    local output
    output=$(get_python_release_manager "3.13.0")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "thomas@python.org" "$cert_identity" "Python 3.13 certificate identity"
    assert_equals "https://accounts.google.com" "$oidc_issuer" "Python 3.13 OIDC issuer"
}

# Test: Python 3.10 release manager (pablogsal@python.org)
test_python_3_10_release_manager() {
    local output
    output=$(get_python_release_manager "3.10.14")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "pablogsal@python.org" "$cert_identity" "Python 3.10 certificate identity"
    assert_equals "https://accounts.google.com" "$oidc_issuer" "Python 3.10 OIDC issuer"
}

# Test: Python 3.9 release manager (lukasz@langa.pl)
test_python_3_9_release_manager() {
    local output
    output=$(get_python_release_manager "3.9.18")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "lukasz@langa.pl" "$cert_identity" "Python 3.9 certificate identity"
    assert_equals "https://github.com/login/oauth" "$oidc_issuer" "Python 3.9 OIDC issuer"
}

# Test: Python 3.8 release manager (lukasz@langa.pl)
test_python_3_8_release_manager() {
    local output
    output=$(get_python_release_manager "3.8.18")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "lukasz@langa.pl" "$cert_identity" "Python 3.8 certificate identity"
    assert_equals "https://github.com/login/oauth" "$oidc_issuer" "Python 3.8 OIDC issuer"
}

# Test: Python 3.14 release manager (hugo@python.org) - future version
test_python_3_14_release_manager() {
    local output
    output=$(get_python_release_manager "3.14.0")
    local cert_identity
    cert_identity=$(echo "$output" | command head -1)
    local oidc_issuer
    oidc_issuer=$(echo "$output" | command tail -1)

    assert_equals "hugo@python.org" "$cert_identity" "Python 3.14 certificate identity"
    assert_equals "https://github.com/login/oauth" "$oidc_issuer" "Python 3.14 OIDC issuer"
}

# Test: Unknown Python version returns error
test_python_unknown_version() {
    # Python 3.99 should not have a mapping
    if get_python_release_manager "3.99.0" >/dev/null 2>&1; then
        assert_true false "Unknown Python version should return error"
    else
        assert_true true "Unknown Python version correctly returns error"
    fi
}

# Test: Python 2.x returns error
test_python_2_version() {
    # Python 2.x is not supported
    if get_python_release_manager "2.7.18" >/dev/null 2>&1; then
        assert_true false "Python 2.x should return error"
    else
        assert_true true "Python 2.x correctly returns error"
    fi
}

# Test: verify_signature function exists
test_verify_signature_exists() {
    if command -v verify_signature >/dev/null 2>&1; then
        assert_true true "verify_signature function exists"
    else
        assert_true false "verify_signature function not found"
    fi
}

# Test: download_and_verify_sigstore function exists
test_download_and_verify_sigstore_exists() {
    if command -v download_and_verify_sigstore >/dev/null 2>&1; then
        assert_true true "download_and_verify_sigstore function exists"
    else
        assert_true false "download_and_verify_sigstore function not found"
    fi
}

# Test: verify_sigstore_signature function exists
test_verify_sigstore_signature_exists() {
    if command -v verify_sigstore_signature >/dev/null 2>&1; then
        assert_true true "verify_sigstore_signature function exists"
    else
        assert_true false "verify_sigstore_signature function not found"
    fi
}

# Run all tests
run_test test_get_python_release_manager_exists "get_python_release_manager function exists"
run_test test_python_3_11_release_manager "Python 3.11 release manager mapping"
run_test test_python_3_12_release_manager "Python 3.12 release manager mapping"
run_test test_python_3_13_release_manager "Python 3.13 release manager mapping"
run_test test_python_3_10_release_manager "Python 3.10 release manager mapping"
run_test test_python_3_9_release_manager "Python 3.9 release manager mapping"
run_test test_python_3_8_release_manager "Python 3.8 release manager mapping"
run_test test_python_3_14_release_manager "Python 3.14 release manager mapping"
run_test test_python_unknown_version "Unknown Python version returns error"
run_test test_python_2_version "Python 2.x returns error"
run_test test_verify_signature_exists "verify_signature function exists"
run_test test_download_and_verify_sigstore_exists "download_and_verify_sigstore function exists"
run_test test_verify_sigstore_signature_exists "verify_sigstore_signature function exists"

# Generate test report
generate_report
