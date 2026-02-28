#!/usr/bin/env bash
# Unit tests for lib/features/lib/install-github-release.sh
# Tests the reusable GitHub release binary installer function

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Install GitHub Release Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/lib/install-github-release.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-install-gh-release-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/usr-local-bin"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: common mock preamble for subshell tests
# Provides all the mock functions that install_github_release depends on.
# Caller appends the actual test commands.
_mock_preamble() {
    command cat <<'MOCK_EOF'
set -euo pipefail

# Mock logging functions
log_message() { :; }
log_warning() { :; }
log_error() { :; }
# log_command: execute the command but redirect /usr/local/bin to temp dir
log_command() {
    shift  # skip description ($1)
    local args=()
    for arg in "$@"; do
        args+=("${arg//\/usr\/local\/bin/$TEST_TEMP_DIR\/usr-local-bin}")
    done
    "${args[@]}"
}
export -f log_message log_warning log_error log_command

# Mock create_secure_temp_dir — creates real dir in TEST_TEMP_DIR
create_secure_temp_dir() {
    local d="$TEST_TEMP_DIR/secure-tmp-$$"
    mkdir -p "$d"
    echo "$d"
}
export -f create_secure_temp_dir

# Create a mock curl binary that creates fake downloaded files
# This is needed because the source uses 'command curl' which bypasses function mocks
MOCK_BIN_DIR="$TEST_TEMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
cat > "$MOCK_BIN_DIR/curl" << 'CURLEOF'
#!/bin/bash
outfile=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) outfile="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
if [ -n "$outfile" ]; then
    echo "fake-binary-content" > "$outfile"
    echo "URL=$url" >&2
fi
exit 0
CURLEOF
chmod +x "$MOCK_BIN_DIR/curl"
export PATH="$MOCK_BIN_DIR:$PATH"

# Mock verify_download — always succeeds
verify_download() {
    return 0
}
export -f verify_download

# Mock register_tool_checksum_fetcher — no-op
# Also declare the associative array it may reference
declare -gA _TOOL_CHECKSUM_FETCHERS 2>/dev/null || true
register_tool_checksum_fetcher() {
    return 0
}
export -f register_tool_checksum_fetcher

# Mock checksum functions (still used inside fetcher registration closures)
fetch_github_checksums_txt() {
    echo "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234"
    return 0
}
export -f fetch_github_checksums_txt

fetch_github_sha512_file() {
    echo "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234"
    return 0
}
export -f fetch_github_sha512_file

validate_checksum_format() { return 0; }
export -f validate_checksum_format

# Mock tar — handles -C flag for extract_flat, or creates fake extracted files
tar() {
    local target_dir=""
    local binary_name=""
    local i=0
    local args=("$@")
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            -C)
                target_dir="${args[$((i+1))]}"
                # The argument after target_dir is the binary name
                if [ $((i+2)) -lt ${#args[@]} ]; then
                    binary_name="${args[$((i+2))]}"
                fi
                i=$((i+3))
                ;;
            -*)
                i=$((i+1))
                ;;
            *)
                i=$((i+1))
                ;;
        esac
    done
    if [ -n "$target_dir" ] && [ -n "$binary_name" ]; then
        mkdir -p "$target_dir"
        echo "fake-extracted-binary" > "$target_dir/$binary_name"
    else
        # Simple extract: create binary in current directory
        mkdir -p extracted
        echo "fake-extracted-binary" > extracted/mytool
    fi
    return 0
}
export -f tar
MOCK_EOF
}

# Helper: run install_github_release in a subshell with mocks
# $1 = extra bash commands to prepend (mock overrides)
# $2...$8 = args to install_github_release
_run_install_subshell() {
    local extra_setup="${1:-}"
    shift
    local tool_name="$1" version="$2" base_url="$3" \
          amd64_file="$4" arm64_file="$5" \
          checksum_type="$6" install_type="$7"

    bash -c "
$(_mock_preamble)

# Mock dpkg for arch detection (default amd64) and package install
dpkg() {
    if [ \"\$1\" = \"--print-architecture\" ]; then
        echo \"amd64\"
        return 0
    fi
    # dpkg -i: no-op
    return 0
}
export -f dpkg

# Redirect /usr/local/bin writes to TEST_TEMP_DIR
mkdir -p \"\$TEST_TEMP_DIR/usr-local-bin\"

# Override mv and chmod to use test dir
# We can't override /usr/local/bin directly, so we patch the source
# Instead, use the real file but intercept at a higher level

$extra_setup

source '$SOURCE_FILE' 2>/dev/null

install_github_release '$tool_name' '$version' '$base_url' \
    '$amd64_file' '$arm64_file' '$checksum_type' '$install_type'
" 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_static_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script uses strict mode"
}

test_static_defensive_guard() {
    assert_file_contains "$SOURCE_FILE" "declare -f log_message" \
        "Script has defensive guard for log_message"
}

test_static_function_definition() {
    assert_file_contains "$SOURCE_FILE" "install_github_release()" \
        "Script defines install_github_release function"
}

test_static_function_export() {
    assert_file_contains "$SOURCE_FILE" "export -f install_github_release" \
        "Script exports install_github_release"
}

test_static_install_type_binary() {
    assert_file_contains "$SOURCE_FILE" "binary)" \
        "Script handles binary install type"
}

test_static_install_type_extract() {
    assert_file_contains "$SOURCE_FILE" "extract:\*)" \
        "Script handles extract install type"
}

test_static_install_type_extract_flat() {
    assert_file_contains "$SOURCE_FILE" "extract_flat:" \
        "Script handles extract_flat install type"
}

test_static_install_type_dpkg() {
    assert_file_contains "$SOURCE_FILE" "dpkg)" \
        "Script handles dpkg install type"
}

test_static_install_type_gunzip() {
    assert_file_contains "$SOURCE_FILE" "gunzip)" \
        "Script handles gunzip install type"
}

test_static_checksum_type_checksums_txt() {
    assert_file_contains "$SOURCE_FILE" "checksums_txt)" \
        "Script handles checksums_txt checksum type"
}

test_static_checksum_type_sha512() {
    assert_file_contains "$SOURCE_FILE" "sha512)" \
        "Script handles sha512 checksum type"
}

test_static_checksum_type_calculate() {
    assert_file_contains "$SOURCE_FILE" "calculate)" \
        "Script handles calculate checksum type"
}

# ============================================================================
# Functional Tests - Defensive guard
# ============================================================================

test_guard_no_log_message() {
    # Source without log_message defined → should return 1
    # Must explicitly unset log_message since it may be exported in the env
    local exit_code=0
    local output
    output=$(bash -c "
        unset -f log_message 2>/dev/null || true
        source '$SOURCE_FILE' 2>&1
    " 2>&1) || exit_code=$?

    # The guard prints an error message and returns 1, but 'return 1' inside
    # a sourced file may not propagate as a non-zero exit from bash -c.
    # Verify via the error message output instead.
    assert_contains "$output" "requires feature-header.sh" \
        "Sourcing without log_message should print guard error"
}

# ============================================================================
# Functional Tests - Architecture detection
# ============================================================================

test_arch_unsupported() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 's390x'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'checksums_txt' 'binary'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "Unsupported architecture should return failure"
}

test_arch_amd64_selects_correct_file() {
    local output
    output=$(bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg

source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com/releases' \
    'tool_amd64.tar.gz' 'tool_arm64.tar.gz' 'checksums_txt' 'binary'
" 2>&1) || true

    assert_contains "$output" "tool_amd64.tar.gz" \
        "amd64 arch should select amd64 filename"
}

test_arch_arm64_selects_correct_file() {
    local output
    output=$(bash -c "
$(_mock_preamble)
dpkg() { echo 'arm64'; }
export -f dpkg

source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com/releases' \
    'tool_amd64.tar.gz' 'tool_arm64.tar.gz' 'checksums_txt' 'binary'
" 2>&1) || true

    assert_contains "$output" "tool_arm64.tar.gz" \
        "arm64 arch should select arm64 filename"
}

# ============================================================================
# Functional Tests - Checksum types
# ============================================================================

test_checksum_checksums_txt_success() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'checksums_txt' 'binary'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "checksums_txt success path should return 0"
}

test_checksum_checksums_txt_fetch_failure() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
# Override verify_download to simulate verification failure
verify_download() { return 1; }
export -f verify_download
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'checksums_txt' 'binary'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "checksums_txt verification failure should return non-zero"
}

test_checksum_sha512_success() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'sha512' 'binary'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "sha512 success path should return 0"
}

test_checksum_sha512_fetch_failure() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
# Override verify_download to simulate verification failure
verify_download() { return 1; }
export -f verify_download
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'sha512' 'binary'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "sha512 verification failure should return non-zero"
}

test_checksum_sha512_validation_failure() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
# Override verify_download to simulate validation failure
verify_download() { return 1; }
export -f verify_download
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'sha512' 'binary'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "sha512 format validation failure should return non-zero"
}

test_checksum_calculate_success() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'calculate' 'binary'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "calculate success path should return 0"
}

test_checksum_calculate_failure() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
# Override verify_download to simulate TOFU/calculation failure
verify_download() { return 1; }
export -f verify_download
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'calculate' 'binary'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "calculate failure should return non-zero"
}

test_checksum_unknown_type() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'tool' '1.0' 'http://example.com' \
    'tool_amd64' 'tool_arm64' 'bogus_type' 'binary'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "Unknown checksum type should return non-zero"
}

# ============================================================================
# Functional Tests - Install types
# ============================================================================

test_install_binary() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'mytool' '1.0' 'http://example.com' \
    'mytool_amd64' 'mytool_arm64' 'checksums_txt' 'binary'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "binary install type should succeed"
}

test_install_extract() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg

# Mock tar to create a fake extracted binary
tar() {
    mkdir -p extracted
    echo 'binary-content' > extracted/mytool
}
export -f tar

source '$SOURCE_FILE' 2>/dev/null
install_github_release 'mytool' '1.0' 'http://example.com' \
    'mytool_amd64.tar.gz' 'mytool_arm64.tar.gz' 'checksums_txt' 'extract:mytool'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "extract install type should succeed"
}

test_install_extract_flat() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'mytool' '1.0' 'http://example.com' \
    'mytool_amd64.tar.gz' 'mytool_arm64.tar.gz' 'checksums_txt' 'extract_flat:mytool'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "extract_flat install type should succeed"
}

test_install_dpkg() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() {
    if [ \"\$1\" = \"--print-architecture\" ]; then
        echo 'amd64'
        return 0
    fi
    # dpkg -i: no-op success
    return 0
}
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'mytool' '1.0' 'http://example.com' \
    'mytool_amd64.deb' 'mytool_arm64.deb' 'checksums_txt' 'dpkg'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "dpkg install type should succeed"
}

test_install_gunzip() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg

# Mock gunzip to simulate decompression (remove the file, create uncompressed)
gunzip() {
    rm -f \"\$1\"
    echo 'decompressed-content' > ./mytool-decompressed
}
export -f gunzip

source '$SOURCE_FILE' 2>/dev/null
install_github_release 'mytool' '1.0' 'http://example.com' \
    'mytool_amd64.gz' 'mytool_arm64.gz' 'checksums_txt' 'gunzip'
" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "gunzip install type should succeed"
}

test_install_unknown_type() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'mytool' '1.0' 'http://example.com' \
    'mytool_amd64' 'mytool_arm64' 'checksums_txt' 'bogus_install'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "Unknown install type should return non-zero"
}

# ============================================================================
# Functional Tests - Download failure
# ============================================================================

test_download_failure() {
    local exit_code=0
    bash -c "
$(_mock_preamble)
dpkg() { echo 'amd64'; }
export -f dpkg
# Override mock curl binary to simulate download failure
command cat > \"\$MOCK_BIN_DIR/curl\" << 'FAILCURL'
#!/bin/bash
exit 1
FAILCURL
chmod +x \"\$MOCK_BIN_DIR/curl\"
source '$SOURCE_FILE' 2>/dev/null
install_github_release 'mytool' '1.0' 'http://example.com' \
    'mytool_amd64' 'mytool_arm64' 'checksums_txt' 'binary'
" 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "download failure should return non-zero"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_static_strict_mode "Static: uses strict mode"
run_test_with_setup test_static_defensive_guard "Static: defensive guard for log_message"
run_test_with_setup test_static_function_definition "Static: defines install_github_release()"
run_test_with_setup test_static_function_export "Static: exports install_github_release"
run_test_with_setup test_static_install_type_binary "Static: handles binary install type"
run_test_with_setup test_static_install_type_extract "Static: handles extract install type"
run_test_with_setup test_static_install_type_extract_flat "Static: handles extract_flat install type"
run_test_with_setup test_static_install_type_dpkg "Static: handles dpkg install type"
run_test_with_setup test_static_install_type_gunzip "Static: handles gunzip install type"
run_test_with_setup test_static_checksum_type_checksums_txt "Static: handles checksums_txt checksum type"
run_test_with_setup test_static_checksum_type_sha512 "Static: handles sha512 checksum type"
run_test_with_setup test_static_checksum_type_calculate "Static: handles calculate checksum type"

# Defensive guard
run_test_with_setup test_guard_no_log_message "Guard: source without log_message fails"

# Architecture detection
run_test_with_setup test_arch_unsupported "Arch: unsupported architecture fails"
run_test_with_setup test_arch_amd64_selects_correct_file "Arch: amd64 selects correct filename"
run_test_with_setup test_arch_arm64_selects_correct_file "Arch: arm64 selects correct filename"

# Checksum types
run_test_with_setup test_checksum_checksums_txt_success "Checksum: checksums_txt success"
run_test_with_setup test_checksum_checksums_txt_fetch_failure "Checksum: checksums_txt fetch failure"
run_test_with_setup test_checksum_sha512_success "Checksum: sha512 success"
run_test_with_setup test_checksum_sha512_fetch_failure "Checksum: sha512 fetch failure"
run_test_with_setup test_checksum_sha512_validation_failure "Checksum: sha512 validation failure"
run_test_with_setup test_checksum_calculate_success "Checksum: calculate success"
run_test_with_setup test_checksum_calculate_failure "Checksum: calculate failure"
run_test_with_setup test_checksum_unknown_type "Checksum: unknown type fails"

# Install types
run_test_with_setup test_install_binary "Install: binary type succeeds"
run_test_with_setup test_install_extract "Install: extract type succeeds"
run_test_with_setup test_install_extract_flat "Install: extract_flat type succeeds"
run_test_with_setup test_install_dpkg "Install: dpkg type succeeds"
run_test_with_setup test_install_gunzip "Install: gunzip type succeeds"
run_test_with_setup test_install_unknown_type "Install: unknown type fails"

# Download failure
run_test_with_setup test_download_failure "Download: failure propagates"

# Generate test report
generate_report
