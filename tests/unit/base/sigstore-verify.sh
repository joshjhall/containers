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
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-sigstore-verify-$unique_id"
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

# run_sigstore - Source the helper in a clean subshell with a pinned stub cosign
#
# Verification goes through require_cosign (#1029), which only accepts a cosign
# that PATH resolves to _COSIGN_BASE_PATH. This places a stub cosign at
# $TEST_TEMP_DIR/bin/cosign, puts that dir first on PATH, and re-points the pin
# at it after sourcing (the seam cosign-require.sh documents), so the rejection
# paths below are reached for their own reason, not an unsatisfied pin.
#
# The stub prints "Verified OK" and records its argv in $TEST_TEMP_DIR/cosign.args.
#
# Args:
#   $1: shell code run after sourcing, before $2 (may be "")
#   $2: the call to run
#   $3: PATH prefix placed before the stub dir (default: none)
#
# Echoes combined output; returns the call's exit code.
run_sigstore() {
    local preamble="$1"
    local call="$2"
    local prefix="${3:-}"
    local stub_bin="$TEST_TEMP_DIR/bin"

    command mkdir -p "$stub_bin"
    command cat >"$stub_bin/cosign" <<MOCK
#!/bin/bash
printf '%s\\n' "\$*" >'$TEST_TEMP_DIR/cosign.args'
echo 'Verified OK'
MOCK
    command chmod +x "$stub_bin/cosign"

    bash -c "
        export PATH='${prefix:+$prefix:}$stub_bin:/usr/bin:/bin'
        _SIGSTORE_VERIFY_LOADED=''
        _COSIGN_REQUIRE_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE'
        _COSIGN_BASE_PATH='$stub_bin/cosign'
        $preamble
        $call
    " 2>&1
}

# write_curl_stub - Place a curl stub (with the given body) in the stub bin dir,
# which run_sigstore puts ahead of /usr/bin on PATH
write_curl_stub() {
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command printf '#!/bin/bash\n%s\n' "$1" >"$TEST_TEMP_DIR/bin/curl"
    command chmod +x "$TEST_TEMP_DIR/bin/curl"
}

# ============================================================================
# Function Export Verification
# ============================================================================

test_exports_verify_sigstore_signature() {
    assert_file_contains "$SOURCE_FILE" "protected_export.*verify_sigstore_signature" \
        "verify_sigstore_signature is exported"
}

test_exports_download_and_verify_sigstore() {
    assert_file_contains "$SOURCE_FILE" "protected_export.*download_and_verify_sigstore" \
        "download_and_verify_sigstore is exported"
}

test_exports_download_and_verify_kubectl_sigstore() {
    assert_file_contains "$SOURCE_FILE" "protected_export.*download_and_verify_kubectl_sigstore" \
        "download_and_verify_kubectl_sigstore is exported"
}

test_exports_get_python_release_manager() {
    assert_file_contains "$SOURCE_FILE" "protected_export.*get_python_release_manager" \
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
    local output
    output=$(run_sigstore "" "verify_sigstore_signature \
        '$TEST_TEMP_DIR/no-such-file.tar.gz' '$TEST_TEMP_DIR/no-such-file.tar.gz.sig' \
        'user@example.org' 'https://accounts.google.com'") || exit_code=$?

    assert_equals "1" "$exit_code" "verify_sigstore_signature returns 1 when target file missing"
    assert_contains "$output" "File not found for Sigstore verification" \
        "Rejected for the missing target, not an unsatisfied cosign pin"
}

# Test: returns 1 when signature file doesn't exist
test_verify_sigstore_missing_sig_file() {
    echo "test content" >"$TEST_TEMP_DIR/testfile.tar.gz"

    local exit_code=0
    local output
    output=$(run_sigstore "" "verify_sigstore_signature \
        '$TEST_TEMP_DIR/testfile.tar.gz' '$TEST_TEMP_DIR/testfile.tar.gz.sig' \
        'user@example.org' 'https://accounts.google.com'") || exit_code=$?

    assert_equals "1" "$exit_code" "verify_sigstore_signature returns 1 when sig file missing"
    assert_contains "$output" "Signature/bundle file not found" \
        "Rejected for the missing signature, not an unsatisfied cosign pin"
}

# Test: returns 1 when cert file specified but doesn't exist
test_verify_sigstore_missing_cert_file() {
    echo "test content" >"$TEST_TEMP_DIR/testfile.tar.gz"
    echo "fake sig" >"$TEST_TEMP_DIR/testfile.tar.gz.sig"

    local exit_code=0
    local output
    output=$(run_sigstore "" "verify_sigstore_signature \
        '$TEST_TEMP_DIR/testfile.tar.gz' '$TEST_TEMP_DIR/testfile.tar.gz.sig' \
        'user@example.org' 'https://accounts.google.com' \
        '$TEST_TEMP_DIR/testfile.tar.gz.crt'") || exit_code=$?

    assert_equals "1" "$exit_code" "verify_sigstore_signature returns 1 when cert file missing"
    assert_contains "$output" "Certificate file not found" \
        "Rejected for the missing certificate, not an unsatisfied cosign pin"
}

# ============================================================================
# verify_sigstore_signature - Bound to the pinned cosign (#1029)
# ============================================================================

# Positive control: with the pinned stub resolving, verification succeeds and
# the stub received the verify-blob call.
test_verify_sigstore_uses_pinned_cosign() {
    echo "test content" >"$TEST_TEMP_DIR/testfile.tar.gz"
    echo "fake bundle" >"$TEST_TEMP_DIR/testfile.tar.gz.sigstore"

    local exit_code=0
    run_sigstore "" "verify_sigstore_signature \
        '$TEST_TEMP_DIR/testfile.tar.gz' '$TEST_TEMP_DIR/testfile.tar.gz.sigstore' \
        'user@example.org' 'https://accounts.google.com'" >/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "verify_sigstore_signature succeeds with the pinned cosign"
    assert_file_contains "$TEST_TEMP_DIR/cosign.args" "verify-blob --bundle" \
        "The pinned cosign received the verify-blob call"
}

# The guard is wired in: a substitute earlier on PATH that would happily print
# "Verified OK" must not be trusted. Without the require_cosign call in
# verify_sigstore_signature this returns 0.
test_verify_sigstore_rejects_shadowed_cosign() {
    echo "test content" >"$TEST_TEMP_DIR/testfile.tar.gz"
    echo "fake bundle" >"$TEST_TEMP_DIR/testfile.tar.gz.sigstore"
    command mkdir -p "$TEST_TEMP_DIR/shadow"
    command printf '#!/bin/bash\necho "Verified OK"\n' >"$TEST_TEMP_DIR/shadow/cosign"
    command chmod +x "$TEST_TEMP_DIR/shadow/cosign"

    local exit_code=0
    local output
    output=$(run_sigstore "" "verify_sigstore_signature \
        '$TEST_TEMP_DIR/testfile.tar.gz' '$TEST_TEMP_DIR/testfile.tar.gz.sigstore' \
        'user@example.org' 'https://accounts.google.com'" "$TEST_TEMP_DIR/shadow") ||
        exit_code=$?

    assert_equals "1" "$exit_code" \
        "verify_sigstore_signature returns 1 when a substitute shadows the base cosign"
    assert_contains "$output" "cosign resolved to $TEST_TEMP_DIR/shadow/cosign" \
        "The rejection comes from require_cosign and names the substitute"
}

# The invocation is bound to COSIGN_BIN, not a second PATH lookup. A cosign
# shell function is defined after the guard (here: require_cosign is replaced
# with one that passes and sets COSIGN_BIN), so a bare `cosign` would run the
# function. Without "$COSIGN_BIN" in verify_sigstore_signature the impostor runs.
test_verify_sigstore_invokes_cosign_bin() {
    echo "test content" >"$TEST_TEMP_DIR/testfile.tar.gz"
    echo "fake bundle" >"$TEST_TEMP_DIR/testfile.tar.gz.sigstore"

    local exit_code=0
    run_sigstore "
        require_cosign() { export COSIGN_BIN='$TEST_TEMP_DIR/bin/cosign'; }
        cosign() { : >'$TEST_TEMP_DIR/impostor.ran'; echo 'Verified OK'; }
    " "verify_sigstore_signature \
        '$TEST_TEMP_DIR/testfile.tar.gz' '$TEST_TEMP_DIR/testfile.tar.gz.sigstore' \
        'user@example.org' 'https://accounts.google.com'" >/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "verify_sigstore_signature succeeds via COSIGN_BIN"
    assert_file_exists "$TEST_TEMP_DIR/cosign.args" \
        "The binary at COSIGN_BIN was invoked"
    # cosign's output goes into `tee | grep -q`, never to $output, so the
    # impostor leaves a marker file rather than printing.
    assert_file_not_exists "$TEST_TEMP_DIR/impostor.ran" \
        "A bare-name cosign (function/PATH) was not invoked"
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

# Without the require_cosign call in download_and_verify_kubectl_sigstore, a
# shadowing substitute would reach the signature downloads; with it, the
# function stops at the guard. curl (called as `command curl`, so it must be a
# PATH stub, not a function) records any call.
test_kubectl_sigstore_rejects_shadowed_cosign() {
    write_curl_stub "echo CURL_CALLED"
    command mkdir -p "$TEST_TEMP_DIR/shadow"
    command printf '#!/bin/bash\necho "Verified OK"\n' >"$TEST_TEMP_DIR/shadow/cosign"
    command chmod +x "$TEST_TEMP_DIR/shadow/cosign"

    local exit_code=0
    local output
    output=$(run_sigstore "" \
        "download_and_verify_kubectl_sigstore '$TEST_TEMP_DIR/kubectl' '1.28.0'" \
        "$TEST_TEMP_DIR/shadow") || exit_code=$?

    assert_equals "1" "$exit_code" \
        "download_and_verify_kubectl_sigstore returns 1 when a substitute shadows cosign"
    assert_contains "$output" "cosign resolved to $TEST_TEMP_DIR/shadow/cosign" \
        "The rejection comes from require_cosign"
    assert_not_contains "$output" "CURL_CALLED" \
        "Nothing is downloaded once the guard rejects cosign"
}

# The kubectl verify-blob call is bound to COSIGN_BIN. The curl stub creates
# empty .sig/.cert files; a cosign shell function stands in for a bare-name
# lookup. Without "$COSIGN_BIN" in the function, the impostor runs.
test_kubectl_sigstore_invokes_cosign_bin() {
    echo "kubectl binary" >"$TEST_TEMP_DIR/kubectl"
    # shellcheck disable=SC2016 # expanded by the stub, not here
    write_curl_stub 'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then : >"$2"; shift; fi; shift; done'

    local exit_code=0
    local output
    output=$(run_sigstore "
        require_cosign() { export COSIGN_BIN='$TEST_TEMP_DIR/bin/cosign'; }
        cosign() { echo IMPOSTOR; }
    " "download_and_verify_kubectl_sigstore '$TEST_TEMP_DIR/kubectl' '1.28.0'") ||
        exit_code=$?

    assert_equals "0" "$exit_code" "download_and_verify_kubectl_sigstore succeeds via COSIGN_BIN"
    assert_file_contains "$TEST_TEMP_DIR/cosign.args" "verify-blob $TEST_TEMP_DIR/kubectl" \
        "The binary at COSIGN_BIN received the kubectl verify-blob call"
    assert_not_contains "$output" "IMPOSTOR" \
        "A bare-name cosign was not invoked"
}

# ============================================================================
# download_and_verify_sigstore - Error Paths
# ============================================================================

# Test: returns 1 when curl fails to download signature
test_download_and_verify_sigstore_curl_failure() {
    # Create a target file
    echo "test content" >"$TEST_TEMP_DIR/testfile.tar.gz"

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

# Pinned-cosign binding (#1029)
run_test_with_setup test_verify_sigstore_uses_pinned_cosign "verify_sigstore_signature: uses pinned cosign"
run_test_with_setup test_verify_sigstore_rejects_shadowed_cosign "verify_sigstore_signature: rejects shadowed cosign"
run_test_with_setup test_verify_sigstore_invokes_cosign_bin "verify_sigstore_signature: invokes COSIGN_BIN"

# download_and_verify_kubectl_sigstore rejection paths
run_test_with_setup test_kubectl_sigstore_cosign_not_installed "kubectl_sigstore: cosign not installed"
run_test_with_setup test_kubectl_sigstore_rejects_shadowed_cosign "kubectl_sigstore: rejects shadowed cosign"
run_test_with_setup test_kubectl_sigstore_invokes_cosign_bin "kubectl_sigstore: invokes COSIGN_BIN"

# download_and_verify_sigstore error paths
run_test_with_setup test_download_and_verify_sigstore_curl_failure "download_and_verify_sigstore: curl failure"

# get_python_release_manager additional mappings
run_test test_python_3_7_release_manager "Python 3.7 release manager (nad)"
run_test test_python_3_15_release_manager "Python 3.15 release manager (hugo)"
run_test test_python_3_16_release_manager "Python 3.16 release manager (savannah)"
run_test test_python_3_17_release_manager "Python 3.17 release manager (savannah)"

# Generate test report
generate_report
