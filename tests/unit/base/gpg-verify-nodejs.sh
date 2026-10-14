#!/bin/bash
# Unit tests for lib/base/gpg-verify-nodejs.sh
# Tests Node.js-specific GPG verification

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "GPG Verify Node.js Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/gpg-verify-nodejs.sh"
PARENT_FILE="$PROJECT_ROOT/lib/base/gpg-verify.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-gpg-verify-nodejs-$unique_id"
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
# Static Analysis Tests
# ============================================================================

# Test: function exists and is exported
test_exports_download_and_verify_nodejs_gpg() {
    assert_file_contains "$SOURCE_FILE" "protected_export.*download_and_verify_nodejs_gpg" \
        "download_and_verify_nodejs_gpg is exported"
}

# Test: function definition exists
test_defines_download_and_verify_nodejs_gpg() {
    assert_file_contains "$SOURCE_FILE" "download_and_verify_nodejs_gpg()" \
        "Script defines download_and_verify_nodejs_gpg function"
}

# Test: sources gpg-verify.sh (via parent module)
test_sourced_by_gpg_verify() {
    assert_file_contains "$PARENT_FILE" "gpg-verify-nodejs.sh" \
        "gpg-verify.sh sources gpg-verify-nodejs.sh"
}

# Test: uses correct keyring name "nodejs"
test_uses_nodejs_keyring() {
    assert_file_contains "$SOURCE_FILE" '"nodejs"' \
        "Uses 'nodejs' keyring name for GPG verification"
}

# Test: URL pattern for SHASUMS256.txt
test_url_pattern_shasums() {
    assert_file_contains "$SOURCE_FILE" 'https://nodejs.org/dist/v${version}/SHASUMS256.txt' \
        "URL pattern: nodejs.org/dist/v{version}/SHASUMS256.txt"
}

# Test: tries .sig first then .asc for signature download
test_tries_sig_then_asc() {
    assert_file_contains "$SOURCE_FILE" "for ext in sig asc" \
        "Tries .sig first then .asc for signature download"
}

# ============================================================================
# Functional Tests
# ============================================================================

# Helper: PATH-stub curl. The source calls `command curl`, which skips shell
# functions, so only a PATH stub intercepts it. URLs ending in .txt are served
# from $TEST_TEMP_DIR/serve/SHASUMS256.txt, .sig from .../SHASUMS256.txt.sig;
# anything missing fails like an unreachable host.
_make_curl_stub() {
    mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/serve"
    command cat >"$TEST_TEMP_DIR/bin/curl" <<STUB
#!/bin/bash
serve='$TEST_TEMP_DIR/serve'
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        -*) shift ;;
        *) url="\$1"; shift ;;
    esac
done
src="\$serve/\${url##*/}"
[ -f "\$src" ] || exit 22
command cat "\$src" >"\$out" || exit 23
STUB
    chmod +x "$TEST_TEMP_DIR/bin/curl"
}

# Helper: run download_and_verify_nodejs_gpg from $TEST_TEMP_DIR/dl with the
# given file argument, GPG signature check mocked to pass. Prints combined log.
_run_nodejs_gpg() {
    local file_arg="$1"
    /usr/bin/env -u BASH_ENV PATH="$TEST_TEMP_DIR/bin:$PATH" /bin/bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$PARENT_FILE' 2>/dev/null
        verify_gpg_signature() { return 0; }
        cd '$TEST_TEMP_DIR/dl'
        download_and_verify_nodejs_gpg '$file_arg' '22.23.3'
    " 2>&1
}

# Test: returns 1 when SHASUMS download fails
test_shasums_download_failure_returns_1() {
    _make_curl_stub # serves nothing
    mkdir -p "$TEST_TEMP_DIR/dl"
    echo "fake node binary" >"$TEST_TEMP_DIR/dl/node-v22.23.3-linux-x64.tar.xz"

    local exit_code=0 output
    output=$(_run_nodejs_gpg "$TEST_TEMP_DIR/dl/node-v22.23.3-linux-x64.tar.xz") || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_nodejs_gpg returns 1 on SHASUMS download failure"
    assert_contains "$output" "Failed to download SHASUMS256.txt" \
        "fails at the SHASUMS download step, not later"
}

# Test: a bare (cwd-relative) filename — how node.sh calls it — verifies (#1255)
test_bare_filename_verifies() {
    _make_curl_stub
    mkdir -p "$TEST_TEMP_DIR/dl"
    local tarball="node-v22.23.3-linux-arm64.tar.xz"
    echo "genuine node arm64" >"$TEST_TEMP_DIR/dl/$tarball"
    local sum
    sum=$(sha256sum "$TEST_TEMP_DIR/dl/$tarball" | command awk '{print $1}')
    printf '%s  %s\n' "$sum" "$tarball" >"$TEST_TEMP_DIR/serve/SHASUMS256.txt"
    echo "fake signature" >"$TEST_TEMP_DIR/serve/SHASUMS256.txt.sig"

    local exit_code=0 output
    output=$(_run_nodejs_gpg "$tarball") || exit_code=$?

    assert_equals "0" "$exit_code" "bare filename verifies against SHASUMS256.txt"
    assert_not_contains "$output" "Failed to download SHASUMS256.txt" \
        "SHASUMS256.txt is written next to the tarball, not under it"
}

# Test: a tarball whose hash isn't the signed one fails, even via bare filename
test_bare_filename_mismatch_returns_1() {
    _make_curl_stub
    mkdir -p "$TEST_TEMP_DIR/dl"
    local tarball="node-v22.23.3-linux-arm64.tar.xz"
    echo "tampered node arm64" >"$TEST_TEMP_DIR/dl/$tarball"
    printf '%s  %s\n' "1111111111111111111111111111111111111111111111111111111111111111" "$tarball" \
        >"$TEST_TEMP_DIR/serve/SHASUMS256.txt"
    echo "fake signature" >"$TEST_TEMP_DIR/serve/SHASUMS256.txt.sig"

    local exit_code=0 output
    output=$(_run_nodejs_gpg "$tarball") || exit_code=$?

    assert_equals "1" "$exit_code" "hash mismatch returns 1"
    assert_contains "$output" "Checksum mismatch" "fails on the checksum comparison"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_exports_download_and_verify_nodejs_gpg "Exports download_and_verify_nodejs_gpg"
run_test test_defines_download_and_verify_nodejs_gpg "Defines download_and_verify_nodejs_gpg function"
run_test test_sourced_by_gpg_verify "gpg-verify.sh sources nodejs sub-module"
run_test test_uses_nodejs_keyring "Uses 'nodejs' keyring name"
run_test test_url_pattern_shasums "URL pattern: SHASUMS256.txt"
run_test test_tries_sig_then_asc "Tries .sig first then .asc"

# Functional tests
run_test_with_setup test_shasums_download_failure_returns_1 "SHASUMS download failure returns 1"
run_test_with_setup test_bare_filename_verifies "Bare filename (as node.sh passes it) verifies"
run_test_with_setup test_bare_filename_mismatch_returns_1 "Bare filename with wrong hash returns 1"

# Generate test report
generate_report
