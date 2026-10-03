#!/usr/bin/env bash
# Unit tests for lib/features/node.sh
# Tests Node.js installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Node.js Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-node-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export NODE_VERSION="22"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/opt/node"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/cache/npm"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.npm"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    command rm -rf "$TEST_TEMP_DIR"

    # Unset test variables
    unset NODE_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Node version selection
test_node_version_selection() {
    # Test default version
    assert_equals "22" "$NODE_VERSION" "Default Node version is 22"

    # Test version override
    NODE_VERSION="20"
    assert_equals "20" "$NODE_VERSION" "Node version can be overridden"

    # Test LTS version mapping
    local version="$NODE_VERSION"
    if [[ "$version" == "22" ]] || [[ "$version" == "20" ]] || [[ "$version" == "18" ]]; then
        assert_true true "Version is a valid LTS version"
    else
        assert_true false "Version is not a valid LTS version"
    fi
}

# Test: Node major version extraction
test_node_major_version_extraction() {
    # Test major version only
    NODE_VERSION="22"
    local major_version
    major_version=$(echo "${NODE_VERSION}" | command cut -d. -f1)
    assert_equals "22" "$major_version" "Major version extracted from '22'"

    # Test specific version
    NODE_VERSION="22.10.0"
    major_version=$(echo "${NODE_VERSION}" | command cut -d. -f1)
    assert_equals "22" "$major_version" "Major version extracted from '22.10.0'"

    # Test version with two parts
    NODE_VERSION="20.5"
    major_version=$(echo "${NODE_VERSION}" | command cut -d. -f1)
    assert_equals "20" "$major_version" "Major version extracted from '20.5'"

    # Test version comparison
    NODE_VERSION="18.19.1"
    major_version=$(echo "${NODE_VERSION}" | command cut -d. -f1)
    if [ "$major_version" -ge 18 ]; then
        assert_true true "Version 18.19.1 meets minimum requirement"
    else
        assert_true false "Version 18.19.1 doesn't meet minimum requirement"
    fi
}

# Test: Node specific version detection
test_node_specific_version_detection() {
    # Test major version only (no dots)
    NODE_VERSION="22"
    if [[ "${NODE_VERSION}" == *"."* ]]; then
        assert_true false "Version '22' incorrectly detected as specific"
    else
        assert_true true "Version '22' correctly detected as major only"
    fi

    # Test specific version (with dots)
    NODE_VERSION="22.10.0"
    if [[ "${NODE_VERSION}" == *"."* ]]; then
        assert_true true "Version '22.10.0' correctly detected as specific"
    else
        assert_true false "Version '22.10.0' incorrectly detected as major only"
    fi

    # Test partial version
    NODE_VERSION="20.5"
    if [[ "${NODE_VERSION}" == *"."* ]]; then
        assert_true true "Version '20.5' correctly detected as specific"
    else
        assert_true false "Version '20.5' incorrectly detected as major only"
    fi
}

# Test: Node installation directory structure
test_node_installation_paths() {
    local node_dir="$TEST_TEMP_DIR/opt/node"
    local node_bin="$node_dir/bin/node"
    local npm_bin="$node_dir/bin/npm"

    # Create mock Node installation
    mkdir -p "$node_dir/bin"
    touch "$node_bin" "$npm_bin"
    chmod +x "$node_bin" "$npm_bin"

    assert_file_exists "$node_bin"
    assert_file_exists "$npm_bin"

    # Check symlinks would be created
    local node_link="$TEST_TEMP_DIR/usr/local/bin/node"
    local npm_link="$TEST_TEMP_DIR/usr/local/bin/npm"

    # Simulate symlink creation
    ln -sf "$node_bin" "$node_link"
    ln -sf "$npm_bin" "$npm_link"

    assert_file_exists "$node_link"
    assert_file_exists "$npm_link"
}

# Test: NPM cache configuration
test_npm_cache_configuration() {
    # shellcheck disable=SC2034  # npm_cache defined for documentation purposes
    local npm_cache="/cache/npm"
    local npmrc_file="$TEST_TEMP_DIR/home/testuser/.npmrc"

    # Create mock .npmrc
    command cat >"$npmrc_file" <<EOF
cache=/cache/npm
prefix=/home/testuser/.npm
EOF

    assert_file_exists "$npmrc_file"

    # Check cache configuration
    if command grep -q "cache=/cache/npm" "$npmrc_file"; then
        assert_true true "NPM cache directory is configured"
    else
        assert_true false "NPM cache directory not configured"
    fi

    if command grep -q "prefix=" "$npmrc_file"; then
        assert_true true "NPM prefix is configured"
    else
        assert_true false "NPM prefix not configured"
    fi
}

# Test: Node bashrc configuration
test_node_bashrc_setup() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/20-node.sh"

    # Create mock Node bashrc
    command cat >"$bashrc_file" <<'EOF'
export NODE_PATH="/opt/node"
export PATH="${NODE_PATH}/bin:${PATH}"
export NPM_CONFIG_PREFIX="${HOME}/.npm"
export NPM_CONFIG_CACHE="/cache/npm"

# Node aliases
alias npm-list="npm list -g --depth=0"
alias npm-outdated="npm outdated -g"
EOF

    assert_file_exists "$bashrc_file"

    # Check environment variables
    if command grep -q "NODE_PATH=" "$bashrc_file"; then
        assert_true true "NODE_PATH is exported"
    else
        assert_true false "NODE_PATH not found"
    fi

    if command grep -q "NPM_CONFIG_CACHE=" "$bashrc_file"; then
        assert_true true "NPM cache config is exported"
    else
        assert_true false "NPM cache config not found"
    fi

    # Check aliases
    if command grep -q "alias npm-list" "$bashrc_file"; then
        assert_true true "npm-list alias is defined"
    else
        assert_true false "npm-list alias not found"
    fi
}

# Test: Node permission handling
test_node_permissions() {
    local node_dir="$TEST_TEMP_DIR/opt/node"
    local npm_dir="$TEST_TEMP_DIR/home/testuser/.npm"
    local cache_dir="$TEST_TEMP_DIR/cache/npm"

    # Create directories
    mkdir -p "$node_dir" "$npm_dir" "$cache_dir"

    # Test ownership commands would be formed correctly
    local chown_npm="chown -R ${USER_UID}:${USER_GID} $npm_dir"
    local chown_cache="chown -R ${USER_UID}:${USER_GID} $cache_dir"

    assert_not_empty "$chown_npm" "NPM directory ownership command formed"
    assert_not_empty "$chown_cache" "Cache directory ownership command formed"

    # Check UID/GID values
    assert_equals "1000" "$USER_UID" "User UID is correct"
    assert_equals "1000" "$USER_GID" "User GID is correct"
}

# ============================================================================
# Corepack provisioning (#983): Node 25+ tarballs no longer bundle corepack
# ============================================================================

# _run_ensure_corepack MODE - run ensure_corepack against PATH stubs
#
# The helper runs under `env -i` with PATH holding only the stub dir plus a
# tools dir of symlinks to the real coreutils/jq the audit classifier calls, so
# the host's own node/corepack can't satisfy it and BASH_ENV can't rebuild PATH.
# MODE picks what the npm stub does on the global `install -g`:
#   bundled     - corepack already present; npm must never run
#   installs    - npm exits 0 and links corepack onto PATH
#   fails       - npm exits 1
#   off-path    - npm exits 0 but links nothing onto PATH
#   fetch-fails - the scratch (non-global) install exits 1
# PIN (optional, default 0.36.0) becomes COREPACK_VERSION; "" leaves it empty.
# AUDIT (env, default clean) picks the `npm audit signatures --json` stdout:
#   clean | mismatch | outage | empty
# VERSION_RC (env, default 0) is the installed corepack's `--version` exit.
#
# Prints the helper's exit code. Each npm call lands as one line in npm.calls
# (args space-joined); log_message/log_error output lands in ensure.log. The
# scratch dir is always $TEST_TEMP_DIR/scratch, so a test can check it is gone.
_run_ensure_corepack() {
    local mode="$1"
    local pin="${2-0.36.0}"
    local audit="${AUDIT:-clean}"
    local version_rc="${VERSION_RC:-0}"
    local stub_bin="$TEST_TEMP_DIR/stub-bin"
    local tools="$TEST_TEMP_DIR/tools"
    local scratch="$TEST_TEMP_DIR/scratch"
    mkdir -p "$stub_bin" "$tools"
    : >"$TEST_TEMP_DIR/npm.calls"
    : >"$TEST_TEMP_DIR/ensure.log"

    local tool
    for tool in jq grep cut tail sed head rm mkdir chmod cat; do
        ln -sf "$(command -v "$tool")" "$tools/$tool"
    done

    local corepack_stub="#!/bin/bash
[ \"\$1\" = --version ] && { [ $version_rc -eq 0 ] && echo 0.36.0; exit $version_rc; }
exit 0"
    if [ "$mode" = "bundled" ]; then
        printf '%s\n' "$corepack_stub" >"$stub_bin/corepack"
        chmod +x "$stub_bin/corepack"
    fi

    local global_action fetch_action="exit 0" audit_out
    case "$mode" in
        installs) global_action="printf '%s\\n' '$corepack_stub' >'$stub_bin/corepack'; chmod +x '$stub_bin/corepack'; exit 0" ;;
        fails) global_action="exit 1" ;;
        fetch-fails)
            global_action="exit 0"
            fetch_action="exit 1"
            ;;
        *) global_action="exit 0" ;;
    esac
    case "$audit" in
        clean) audit_out='{"invalid":[],"missing":[]}' ;;
        mismatch) audit_out='{"invalid":[{"name":"corepack","version":"0.36.0"}],"missing":[]}' ;;
        outage) audit_out='{"error":{"code":"ECONNREFUSED","summary":"request failed"}}' ;;
        empty) audit_out='' ;;
    esac

    command cat >"$stub_bin/npm" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>'$TEST_TEMP_DIR/npm.calls'
case "\$1" in
    install)
        case " \$* " in
            *" -g "*) $global_action ;;
            *) $fetch_action ;;
        esac
        ;;
    audit) printf '%s' '$audit_out'; exit 1 ;;
esac
exit 0
STUB
    chmod +x "$stub_bin/npm"

    local rc=0
    env -i PATH="$stub_bin:$tools" COREPACK_VERSION="$pin" SCRATCH="$scratch" \
        LOG="$TEST_TEMP_DIR/ensure.log" /bin/bash -c '
        log_message() { printf "MSG: %s\n" "$*" >>"$LOG"; }
        log_error() { printf "ERR: %s\n" "$*" >>"$LOG"; }
        log_command() { shift; "$@"; }
        create_secure_temp_dir() { mkdir -p "$SCRATCH" && printf "%s\n" "$SCRATCH"; }
        source "$1"
        source "$2"
        ensure_corepack
    ' _ "$PROJECT_ROOT/lib/features/lib/npm-audit-verdict.sh" \
        "$PROJECT_ROOT/lib/features/lib/node/ensure-corepack.sh" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# _npm_global_installs - the `npm install -g` lines from the last run
_npm_global_installs() {
    command grep -E '^install( .*)? -g( |$)' "$TEST_TEMP_DIR/npm.calls" || true
}

test_corepack_bundled_skips_npm() {
    local rc
    rc=$(_run_ensure_corepack bundled)
    assert_equals "0" "$rc" "ensure_corepack succeeds when corepack is bundled"
    assert_equals "" "$(command cat "$TEST_TEMP_DIR/npm.calls")" \
        "npm is not invoked when corepack is bundled"
}

# A clean audit installs the AUDITED directory, never a fresh resolve of the
# name, and every npm call keeps its cache inside the scratch dir (#985).
test_corepack_missing_installs_verified() {
    local rc scratch="$TEST_TEMP_DIR/scratch"
    rc=$(_run_ensure_corepack installs)
    assert_equals "0" "$rc" "ensure_corepack succeeds after a clean audit"
    assert_equals "install --prefix $scratch --cache $scratch/.npm-cache --ignore-scripts corepack@0.36.0
audit signatures --json --cache $scratch/.npm-cache
install -g --cache $scratch/.npm-cache --ignore-scripts --install-links $scratch/node_modules/corepack" \
        "$(command cat "$TEST_TEMP_DIR/npm.calls")" \
        "fetch to scratch, audit it, then install -g from the audited dir"
    assert_false "[ -e '$scratch' ]" "the scratch dir (and its npm cache) is removed"
    assert_file_contains "$TEST_TEMP_DIR/ensure.log" "corepack 0.36.0 installed (registry signature verified)" \
        "success is logged with the verified version"
}

test_corepack_signature_mismatch_is_fatal() {
    local rc
    rc=$(AUDIT=mismatch _run_ensure_corepack installs)
    assert_equals "1" "$rc" "ensure_corepack fails on a signature mismatch"
    assert_equals "" "$(_npm_global_installs)" "nothing is installed globally after a mismatch"
    assert_file_contains "$TEST_TEMP_DIR/ensure.log" "signature verification FAILED" \
        "a mismatch gets its own supply-chain error"
    assert_false "[ -e '$TEST_TEMP_DIR/scratch' ]" "the scratch dir is removed on failure too"
}

# corepack is required, so unlike agnix an audit that could not run is fatal
# rather than skipped — and must not be reported as tampering.
test_corepack_unverifiable_audit_is_fatal() {
    local rc audit
    for audit in outage empty; do
        rc=$(AUDIT=$audit _run_ensure_corepack installs)
        assert_equals "1" "$rc" "ensure_corepack fails when the audit is '$audit'"
        assert_equals "" "$(_npm_global_installs)" "nothing is installed globally when the audit is '$audit'"
        assert_file_contains "$TEST_TEMP_DIR/ensure.log" "signature could not be verified" \
            "an '$audit' audit is reported as unverifiable"
        assert_file_not_contains "$TEST_TEMP_DIR/ensure.log" "verification FAILED" \
            "an '$audit' audit is not reported as a mismatch"
    done
}

test_corepack_fetch_failure_is_fatal() {
    local rc
    rc=$(_run_ensure_corepack fetch-fails)
    assert_equals "1" "$rc" "ensure_corepack fails when the scratch fetch fails"
    assert_file_not_contains "$TEST_TEMP_DIR/npm.calls" "audit" \
        "no audit runs when there is nothing fetched to audit"
    assert_equals "" "$(_npm_global_installs)" "nothing is installed globally"
}

test_corepack_install_failure_is_fatal() {
    local rc
    rc=$(_run_ensure_corepack fails)
    assert_equals "1" "$rc" "ensure_corepack fails when npm install -g fails"
    assert_false "[ -e '$TEST_TEMP_DIR/scratch' ]" "the scratch dir is removed on failure"
}

test_corepack_install_off_path_is_fatal() {
    local rc
    rc=$(_run_ensure_corepack off-path)
    assert_equals "1" "$rc" "ensure_corepack fails when corepack is still not on PATH"
}

# The success line asks corepack for its version; a corepack that cannot answer
# is still installed, and the line falls back to the pin.
test_corepack_version_query_failure_logs_pin() {
    local rc
    rc=$(VERSION_RC=1 _run_ensure_corepack installs)
    assert_equals "0" "$rc" "a failing 'corepack --version' does not fail the install"
    assert_file_contains "$TEST_TEMP_DIR/ensure.log" "corepack 0.36.0 installed" \
        "the success line falls back to COREPACK_VERSION"
}

test_corepack_missing_without_pin_is_fatal() {
    local rc
    rc=$(_run_ensure_corepack installs "")
    assert_equals "1" "$rc" "ensure_corepack fails when corepack is missing and no pin is set"
    assert_equals "" "$(command cat "$TEST_TEMP_DIR/npm.calls")" \
        "npm is not invoked without a pin (no unpinned install)"
}

test_corepack_non_exact_pin_is_fatal() {
    local rc pin
    for pin in latest "^0.36.0" "0.36" "0.36.0 --foo"; do
        rc=$(_run_ensure_corepack installs "$pin")
        assert_equals "1" "$rc" "ensure_corepack rejects COREPACK_VERSION='$pin'"
        assert_equals "" "$(command cat "$TEST_TEMP_DIR/npm.calls")" \
            "npm is not invoked for COREPACK_VERSION='$pin'"
    done
}

# libatomic1 (#983): node 26's arm64 binary links libatomic.so.1 and exits 127
# without it. Run the real install_node_system_deps against a recording
# apt_install rather than grepping node.sh for the package name.
test_node_system_deps_include_libatomic() {
    local requested
    requested=$(env -i PATH=/usr/bin:/bin /bin/bash -c '
        apt_install() { printf "%s\n" "$@"; }
        source "$1"
        install_node_system_deps
    ' _ "$PROJECT_ROOT/lib/features/lib/node/system-deps.sh")
    assert_equals "curl
ca-certificates
xz-utils
libatomic1" "$requested" "install_node_system_deps requests libatomic1 with the download deps"
    assert_file_contains "$PROJECT_ROOT/lib/features/node.sh" "^install_node_system_deps$" \
        "node.sh calls install_node_system_deps"
}

# The pin must use the override pattern: bin/check-versions.sh reads it and
# the weekly auto-patch rewrites it. That ensure_corepack runs before
# `corepack enable` is proven by tests/integration/builds/test_node_current.sh,
# which fails to build without it; a line-number check here would not be.
test_corepack_pinned() {
    local node_script="$PROJECT_ROOT/lib/features/node.sh"
    assert_file_contains "$node_script" 'COREPACK_VERSION="${COREPACK_VERSION:-' \
        "node.sh pins COREPACK_VERSION with an override default"
    assert_file_not_contains "$node_script" "corepack@latest" \
        "node.sh must not install corepack@latest"
}

# Test: Node version verification
test_node_version_verification() {
    local test_script="$TEST_TEMP_DIR/usr/local/bin/test-node"

    # Create mock verification script
    command cat >"$test_script" <<'EOF'
#!/bin/bash
echo "Node.js version:"
node --version 2>/dev/null || echo "Node not installed"
echo "NPM version:"
npm --version 2>/dev/null || echo "NPM not installed"
echo "Yarn version:"
yarn --version 2>/dev/null || echo "Yarn not available"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check verification content
    if command grep -q "node --version" "$test_script"; then
        assert_true true "Script checks Node version"
    else
        assert_true false "Script doesn't check Node version"
    fi

    if command grep -q "npm --version" "$test_script"; then
        assert_true true "Script checks NPM version"
    else
        assert_true false "Script doesn't check NPM version"
    fi
}

# Test: Node PATH configuration
test_node_path_configuration() {
    local node_path="/opt/node"
    local node_bin_path="$node_path/bin"
    local npm_global_path="/home/testuser/.npm/bin"

    # Test PATH would include Node directories
    local expected_path="$node_bin_path:$npm_global_path"

    assert_not_empty "$expected_path" "Node PATH additions are defined"

    if [[ "$expected_path" == *"/opt/node/bin"* ]]; then
        assert_true true "Node bin directory in PATH"
    else
        assert_true false "Node bin directory not in PATH"
    fi

    if [[ "$expected_path" == *"/.npm/bin"* ]]; then
        assert_true true "NPM global bin directory in PATH"
    else
        assert_true false "NPM global bin directory not in PATH"
    fi
}

# Test: Node helper functions
test_node_helper_functions() {
    # Test helper function definitions
    local npm_clean_func='npm-clean() { npm cache clean --force; }'
    local npm_audit_func='npm-security-audit() { npm audit; }'

    assert_not_empty "$npm_clean_func" "npm-clean function is defined"
    assert_not_empty "$npm_audit_func" "npm-security-audit function is defined"

    # Check function structure
    if [[ "$npm_clean_func" == *"cache clean"* ]]; then
        assert_true true "npm-clean uses cache clean command"
    else
        assert_true false "npm-clean function incorrect"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_node_version_selection "Node version selection and override"
run_test_with_setup test_node_major_version_extraction "Node major version extraction from various formats"
run_test_with_setup test_node_specific_version_detection "Node specific version detection logic"
run_test_with_setup test_node_installation_paths "Node installation directory structure"
run_test_with_setup test_npm_cache_configuration "NPM cache configuration"
run_test_with_setup test_node_bashrc_setup "Node bashrc configuration"
run_test_with_setup test_node_permissions "Node permission handling"
run_test_with_setup test_corepack_bundled_skips_npm "Bundled corepack is used as-is"
run_test_with_setup test_corepack_missing_installs_verified "Missing corepack is audited, then installed from the audited dir"
run_test_with_setup test_corepack_signature_mismatch_is_fatal "corepack signature mismatch fails the build"
run_test_with_setup test_corepack_unverifiable_audit_is_fatal "Unverifiable corepack audit fails the build"
run_test_with_setup test_corepack_fetch_failure_is_fatal "corepack scratch fetch failure fails the build"
run_test_with_setup test_corepack_install_failure_is_fatal "corepack install failure fails the build"
run_test_with_setup test_corepack_install_off_path_is_fatal "corepack not on PATH after install fails the build"
run_test_with_setup test_corepack_version_query_failure_logs_pin "Failing corepack --version falls back to the pin in the log"
run_test_with_setup test_corepack_missing_without_pin_is_fatal "Missing corepack with no pin fails without installing"
run_test_with_setup test_corepack_non_exact_pin_is_fatal "Non-exact COREPACK_VERSION is rejected before npm runs"
run_test_with_setup test_corepack_pinned "COREPACK_VERSION pinned with an override default"
run_test_with_setup test_node_system_deps_include_libatomic "System deps include libatomic1 (behavioral)"
run_test_with_setup test_node_version_verification "Node version verification script"
run_test_with_setup test_node_path_configuration "Node PATH configuration"
run_test_with_setup test_node_helper_functions "Node helper functions"

# ============================================================================
# Security Verification Tests
# ============================================================================

# Test: node.sh does not use curl | bash
test_no_curl_pipe_bash() {
    local node_script="$PROJECT_ROOT/lib/features/node.sh"

    if ! [ -f "$node_script" ]; then
        skip_test "node.sh not found"
        return
    fi

    # Check for curl | bash pattern (should NOT exist)
    if command grep -E "curl.*\|.*bash" "$node_script" >/dev/null 2>&1; then
        assert_true false "CRITICAL: node.sh contains 'curl | bash' pattern"
    else
        assert_true true "node.sh does not use 'curl | bash' pattern"
    fi

    # Check for wget | bash pattern (should NOT exist)
    if command grep -E "wget.*\|.*bash" "$node_script" >/dev/null 2>&1; then
        assert_true false "CRITICAL: node.sh contains 'wget | bash' pattern"
    else
        assert_true true "node.sh does not use 'wget | bash' pattern"
    fi
}

# Test: node.sh uses manual repository setup
test_manual_repository_setup() {
    local node_script="$PROJECT_ROOT/lib/features/node.sh"

    if ! [ -f "$node_script" ]; then
        skip_test "node.sh not found"
        return
    fi

    # Check for 4-tier verification system (replaced repository setup)
    if command grep -q "checksum-verification.sh" "$node_script"; then
        assert_true true "node.sh sources 4-tier checksum verification system"
    else
        assert_true false "node.sh does not source checksum-verification.sh"
    fi

    # Check for verify_download usage
    if command grep -q "verify_download" "$node_script"; then
        assert_true true "node.sh uses verify_download for binary verification"
    else
        assert_true false "node.sh does not use verify_download"
    fi
}

# Test: node.sh downloads binaries directly (no repository)
test_repository_sources_list() {
    local node_script="$PROJECT_ROOT/lib/features/node.sh"

    if ! [ -f "$node_script" ]; then
        skip_test "node.sh not found"
        return
    fi

    # Check that repository setup is NOT used (direct binary download instead)
    if command grep -q "/etc/apt/sources.list.d/nodesource.list" "$node_script"; then
        assert_true false "node.sh should not use repository setup (uses direct download)"
    else
        assert_true true "node.sh correctly uses direct binary download (no repository)"
    fi

    # Check that Node.js is downloaded from dist URLs
    if command grep -q "nodejs.org/dist" "$node_script"; then
        assert_true true "node.sh downloads from nodejs.org/dist"
    else
        assert_true false "node.sh does not download from official dist URL"
    fi
}

# Run security tests
run_test test_no_curl_pipe_bash "node.sh does not use curl | bash pattern"
run_test test_manual_repository_setup "node.sh uses 4-tier verification system"
run_test test_repository_sources_list "node.sh uses direct binary download (no repository)"

# Generate test report
generate_report
