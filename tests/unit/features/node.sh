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
#   clean | mismatch | outage | empty | unsigned | no-missing | null-missing
#   | noisy-clean (a clean body wrapped in npm notice prose)
# NO_SCRATCH (env, non-empty) makes create_secure_temp_dir fail.
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
        unsigned) audit_out='{"invalid":[],"missing":[{"name":"corepack","version":"0.36.0"}]}' ;;
        no-missing) audit_out='{"invalid":[]}' ;;
        null-missing) audit_out='{"invalid":[],"missing":null}' ;;
        noisy-clean) audit_out='npm notice update available
{"invalid":[],"missing":[]}
npm notice bye' ;;
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
        NO_SCRATCH="${NO_SCRATCH:-}" \
        LOG="$TEST_TEMP_DIR/ensure.log" /bin/bash -c '
        log_message() { printf "MSG: %s\n" "$*" >>"$LOG"; }
        log_error() { printf "ERR: %s\n" "$*" >>"$LOG"; }
        log_command() { shift; "$@"; }
        create_secure_temp_dir() {
            [ -n "$NO_SCRATCH" ] && return 1
            mkdir -p "$SCRATCH" && printf "%s\n" "$SCRATCH"
        }
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

# A package served with no registry signature lands in missing[], not
# invalid[]; the shared classifier alone would read that as clean (#985 review).
# An absent or null missing[] is not evidence of a signature either: jq reads
# `null | length` as 0, so only the type check keeps those from installing.
test_corepack_unsigned_is_fatal() {
    local rc audit
    for audit in unsigned no-missing null-missing; do
        rc=$(AUDIT=$audit _run_ensure_corepack installs)
        assert_equals "1" "$rc" "ensure_corepack fails when the audit is '$audit'"
        assert_equals "" "$(_npm_global_installs)" "nothing is installed globally when the audit is '$audit'"
        assert_file_contains "$TEST_TEMP_DIR/ensure.log" "Refusing to install unsigned" \
            "an '$audit' audit is refused as unsigned"
    done
}

# The unsigned check reads the same selected body as the classifier, so npm
# prose around a clean audit must not turn into a false refusal.
test_corepack_noisy_clean_audit_installs() {
    local rc
    rc=$(AUDIT=noisy-clean _run_ensure_corepack installs)
    assert_equals "0" "$rc" "a clean audit wrapped in npm notices still installs"
    assert_file_not_contains "$TEST_TEMP_DIR/ensure.log" "Refusing" \
        "notice prose is not mistaken for an unsigned package"
}

test_corepack_scratch_dir_failure_is_fatal() {
    local rc
    rc=$(NO_SCRATCH=1 _run_ensure_corepack installs)
    assert_equals "1" "$rc" "ensure_corepack fails when no scratch dir can be created"
    assert_equals "" "$(command cat "$TEST_TEMP_DIR/npm.calls")" \
        "npm is not invoked without a scratch dir"
    assert_file_contains "$TEST_TEMP_DIR/ensure.log" "Could not create a scratch directory" \
        "the scratch-dir failure is logged"
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
}

# _run_node_sh_prefix NODE_SH - run node.sh up to `ensure_corepack || exit 1`
#
# The prefix is cut out of NODE_SH (the real node.sh, or a mutated copy) and
# each `source /tmp/build-scripts/<rel>` is rewritten to `_src <rel>`. _src
# sources the real lib/features/lib/* helpers and skips base/*, whose functions
# are stubbed here; an unstubbed new dependency fails the run rather than
# no-opping. apt_install records its args to apt.calls, and ensure_corepack is
# replaced (once its file is sourced) by a recorder writing whether
# npm_audit_verdict was defined at the moment node.sh called it.
#
# Prints the prefix's exit code, or "no-prefix" if the cut-off line is missing.
_run_node_sh_prefix() {
    local node_sh="$1"
    local prefix="$TEST_TEMP_DIR/node-prefix.sh"
    local stub_bin="$TEST_TEMP_DIR/stub-bin"
    local tools="$TEST_TEMP_DIR/tools"
    mkdir -p "$stub_bin" "$tools"
    : >"$TEST_TEMP_DIR/apt.calls"
    command rm -f "$TEST_TEMP_DIR/corepack.call"

    # The luggage calls are pointed at a stub that succeeds: this harness
    # proves the deps/audit/corepack wiring, not the install (tested below).
    # The default NODE_VERSION (22) is a partial, so `resolve` must answer
    # the way real luggage does: pretty-printed, top-level version.
    printf '#!/bin/bash\n[ "$1" = resolve ] && printf "{\\n  \\"version\\": \\"22.23.4\\"\\n}\\n"\nexit 0\n' \
        >"$stub_bin/luggage"
    command chmod +x "$stub_bin/luggage"
    command awk -v luggage="$stub_bin/luggage" '
        { sub(/^source \/tmp\/build-scripts\//, "_src "); gsub(/\/usr\/local\/bin\/luggage/, luggage) }
        { print }
        /^ensure_corepack \|\| exit 1$/ { exit }' "$node_sh" >"$prefix"
    if ! command grep -qx 'ensure_corepack || exit 1' "$prefix"; then
        echo "no-prefix"
        return 0
    fi

    local tool
    for tool in cut rm mktemp cat sed; do
        ln -sf "$(command -v "$tool")" "$tools/$tool"
    done

    local rc=0
    env -i PATH="$stub_bin:$tools" ROOT="$PROJECT_ROOT" OUT="$TEST_TEMP_DIR" USERNAME=vscode \
        /bin/bash -c '
        _src() {
            case "$1" in
                base/*) return 0 ;;
            esac
            source "$ROOT/lib/$1"
            if [ "$1" = features/lib/node/ensure-corepack.sh ]; then
                ensure_corepack() {
                    if declare -F npm_audit_verdict >/dev/null; then
                        echo defined
                    else
                        echo undefined
                    fi >>"$OUT/corepack.call"
                }
            fi
        }
        log_message() { :; }
        log_error() { :; }
        log_feature_start() { :; }
        log_feature_end() { :; }
        log_command() { shift; "$@"; }
        validate_node_version() { :; }
        apt_update() { :; }
        apt_install() { printf "%s\n" "$@" >>"$OUT/apt.calls"; }
        source "$1"
    ' _ "$prefix" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# node.sh's own wiring, behaviorally: the unit test above proves the helper
# requests libatomic1, this proves node.sh actually calls it, and that the
# verdict classifier ensure_corepack relies on is loaded by the time node.sh
# reaches ensure_corepack (a source line moved below the call would leave
# npm_audit_verdict undefined only on the Node 25+ install path).
test_node_sh_wires_deps_and_audit_before_corepack() {
    local rc
    rc=$(_run_node_sh_prefix "$PROJECT_ROOT/lib/features/node.sh")
    assert_equals "0" "$rc" "node.sh runs cleanly up to ensure_corepack"
    assert_equals "curl
ca-certificates
xz-utils
libatomic1" "$(command cat "$TEST_TEMP_DIR/apt.calls")" \
        "node.sh installs the system deps, libatomic1 included"
    assert_equals "defined" "$(command cat "$TEST_TEMP_DIR/corepack.call" 2>/dev/null)" \
        "npm_audit_verdict is defined when node.sh calls ensure_corepack"
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
run_test_with_setup test_corepack_unsigned_is_fatal "Unsigned corepack (missing[]) fails the build"
run_test_with_setup test_corepack_noisy_clean_audit_installs "Clean audit wrapped in npm notices installs"
run_test_with_setup test_corepack_scratch_dir_failure_is_fatal "Scratch-dir creation failure fails the build"
run_test_with_setup test_corepack_fetch_failure_is_fatal "corepack scratch fetch failure fails the build"
run_test_with_setup test_corepack_install_failure_is_fatal "corepack install failure fails the build"
run_test_with_setup test_corepack_install_off_path_is_fatal "corepack not on PATH after install fails the build"
run_test_with_setup test_corepack_version_query_failure_logs_pin "Failing corepack --version falls back to the pin in the log"
run_test_with_setup test_corepack_missing_without_pin_is_fatal "Missing corepack with no pin fails without installing"
run_test_with_setup test_corepack_non_exact_pin_is_fatal "Non-exact COREPACK_VERSION is rejected before npm runs"
run_test_with_setup test_corepack_pinned "COREPACK_VERSION pinned with an override default"
run_test_with_setup test_node_system_deps_include_libatomic "System deps include libatomic1 (behavioral)"
run_test_with_setup test_node_sh_wires_deps_and_audit_before_corepack "node.sh installs deps and loads the audit verdict before ensure_corepack"
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

# ============================================================================
# luggage delegation (#812)
# ============================================================================
# node.sh delegates the Node.js install to `luggage install` (#812): arch
# selection (node's "x64" spelling lives in the catalog as one install method
# per arch), download, tier-3 SHASUMS256.txt manifest verification, xz
# extraction and the strip into /usr/local all live in the luggage engine and
# the containers-db catalog now. The tests below run node.sh's real version
# block and install statement against a stub luggage;
# tests/integration/builds/test_luggage_node.sh runs them against the real
# engine.

# Test: the install itself is luggage's — node.sh carries none of it. The
# behavioral tests below prove what the delegation DOES; this pins what was
# removed, so a partial revert that re-adds a second download path fails.
test_node_sh_has_no_inline_install() {
    local node_script="$PROJECT_ROOT/lib/features/node.sh"
    local pattern
    for pattern in 'curl -fsSL' 'verify_download_or_fail' 'tar -xJf' \
        'checksum-verification.sh' 'download-verify.sh' 'nodejs.org/dist'; do
        assert_file_not_contains "$node_script" "$pattern" \
            "node.sh no longer contains '$pattern' (the install is luggage's)"
    done
}

# Run node.sh's real version block — input validation, the pre-18 floor, and
# the partial resolve — against a stub luggage, and print what it decided.
# Extracting the block from the script (not copying it) and sourcing the real
# version-validation.sh keeps these tests on the code that ships, entry check
# included. Usage: run_version_block <NODE_VERSION> <stub-luggage-body>
# Prints "RESULT: <version>" on success, the logged errors on failure, and
# returns the block's exit status.
run_version_block() {
    local node_version="$1" stub_body="$2"
    local node_script="$PROJECT_ROOT/lib/features/node.sh"
    local stub="$TEST_TEMP_DIR/luggage-stub" block="$TEST_TEMP_DIR/version-block.sh"

    printf '#!/bin/bash\n%s\n' "$stub_body" >"$stub"
    command chmod +x "$stub"
    # The same extractor the luggage_node fixture runs against real luggage
    # output, here with luggage's absolute path redirected to the stub.
    bash "$PROJECT_ROOT/tests/integration/builds/luggage_node/extract-version-block.sh" \
        "$node_script" "$stub" >"$block"

    # Its own bash process, so errexit holds: callers run this as
    # `out=$(run_version_block …) || rc=$?`, and a subshell in that position
    # runs with errexit suspended — an unhandled failure in the block would be
    # stepped over instead of aborting it the way the real build does.
    # shellcheck disable=SC2016  # expanded by the inner bash, not here
    bash -c '
        set -euo pipefail
        log_error() { echo "ERR: $*"; }
        log_message() { :; }
        source "$1"
        NODE_VERSION="$2"
        source "$3"
        echo "RESULT: $NODE_VERSION"
    ' _ "$PROJECT_ROOT/lib/base/version-validation.sh" "$node_version" "$block"
}

# luggage resolve --json, as it really pretty-prints: two-space indent and the
# top-level version mid-object. The decoy is a dependency carrying its own
# `"version": "…"` key, printed FIRST at a deeper indent: an unanchored match
# would take "9.9.9".
NODE_RESOLVE_JSON='{
  "tool": "node",
  "dependencies": [
    {
      "tool": "ca_certificates",
      "version": "9.9.9"
    }
  ],
  "version": "22.23.4",
  "method_name": "node-tarball-amd64"
}'

# Test: a major-only pin ("22") resolves through luggage to the newest patch,
# and asks luggage for exactly that partial
test_major_version_resolves_via_luggage() {
    local out rc=0 argv="$TEST_TEMP_DIR/resolve-argv"
    command rm -f "$argv"
    out=$(run_version_block "22" "printf '%s\n' \"\$*\" >'$argv'
command cat <<'JSON'
$NODE_RESOLVE_JSON
JSON") || rc=$?
    assert_equals "0" "$rc" "major-only 22 resolves (exit 0)"
    assert_contains "$out" "RESULT: 22.23.4" "resolves to the top-level version, not the nested dependency's 9.9.9"
    assert_equals "resolve node --version 22 --catalog /opt/containers-db --json" \
        "$(command cat "$argv" 2>/dev/null)" "luggage resolve is asked for node, partial 22, default catalog, JSON"
}

# Test: a major.minor pin ("22.12") resolves too; version as the last key
# (no trailing comma) still parses
test_partial_minor_resolves_via_luggage() {
    local out rc=0
    out=$(run_version_block "22.12" "cat <<'JSON'
{
  \"tool\": \"node\",
  \"version\": \"22.12.0\"
}
JSON") || rc=$?
    assert_equals "0" "$rc" "partial 22.12 resolves (exit 0)"
    assert_contains "$out" "RESULT: 22.12.0" "parsed 22.12.0"
}

# Test: an exact pin skips resolution entirely (luggage must not be called)
test_exact_version_skips_resolve() {
    local out rc=0
    out=$(run_version_block "22.12.0" 'echo "luggage must not be called for an exact pin" >&2; exit 99') || rc=$?
    assert_equals "0" "$rc" "exact 22.12.0 passes through"
    assert_contains "$out" "RESULT: 22.12.0" "exact version unchanged"
}

# Test: a failing luggage resolve fails the build and surfaces luggage's reason
test_resolve_failure_surfaces_luggage_error() {
    local out rc=0
    out=$(run_version_block "27" 'echo "error: no version of `node` matches spec `partial:27`" >&2; exit 1') || rc=$?
    assert_not_equals "0" "$rc" "a failed resolve exits non-zero"
    assert_contains "$out" "Could not resolve Node.js 27" "names the request"
    assert_contains "$out" "partial:27" "carries luggage's own stderr, not a guessed cause"
}

# Test: luggage succeeding with no top-level version is an error, not ""
test_resolve_without_version_fails_closed() {
    local out rc=0
    out=$(run_version_block "22" "cat <<'JSON'
{
  \"tool\": \"node\",
  \"method_name\": \"node-tarball-amd64\"
}
JSON") || rc=$?
    assert_not_equals "0" "$rc" "no top-level version exits non-zero"
    assert_contains "$out" "carried no top-level version" "fails closed instead of installing node@\"\""
}

# Test: Node < 18 is refused up front — major, partial and exact form — before
# luggage is reached; the floor itself is accepted
test_pre_floor_versions_refused() {
    local v out rc
    for v in 16 16.20 16.20.2; do
        rc=0
        out=$(run_version_block "$v" 'echo "luggage must not be reached below the floor" >&2; exit 99') || rc=$?
        assert_not_equals "0" "$rc" "Node $v is refused"
        assert_contains "$out" "must be 18 or higher" "Node $v refusal names the floor"
        assert_not_contains "$out" "luggage must not be reached" "Node $v never reaches luggage"
    done
    rc=0
    out=$(run_version_block "18.0.0" 'exit 99') || rc=$?
    assert_equals "0" "$rc" "Node 18.0.0 (the floor) is accepted"
}

# Test: input validation still runs first — a malformed pin never reaches
# the floor check or luggage
test_invalid_version_rejected_by_validation() {
    local out rc=0
    out=$(run_version_block "22.x" 'echo "luggage must not be reached" >&2; exit 99') || rc=$?
    assert_not_equals "0" "$rc" "NODE_VERSION=22.x is rejected"
    assert_contains "$out" "Invalid NODE_VERSION format" "rejected by input validation"
}

# Extract node.sh's install statement (log_command line through the first
# line that does not continue) with luggage redirected to STUB.
_node_install_block() {
    local stub="$1" out="$2"
    command awk '/log_command "luggage install node@/{f=1} f{print; if ($0 !~ /\\$/) exit}' \
        "$PROJECT_ROOT/lib/features/node.sh" |
        command sed "s#/usr/local/bin/luggage#$stub#g" >"$out"
}

# Test: a failing luggage install aborts the feature script. Runs the real
# install statement under the script's own `set -euo pipefail` with a luggage
# stub that exits 1, then checks the line after it never ran — catching every
# way of swallowing the failure (`|| true`, `|| :`, an `if` wrapper).
test_luggage_install_failure_aborts() {
    local stub="$TEST_TEMP_DIR/luggage-fail-stub" block="$TEST_TEMP_DIR/install-block.sh"
    printf '#!/bin/bash\necho "stub luggage: install failed" >&2\nexit 1\n' >"$stub"
    command chmod +x "$stub"
    _node_install_block "$stub" "$block"
    if [ ! -s "$block" ]; then
        assert_true false "Could not locate the luggage install block"
        return
    fi

    # Its own bash process, NOT `out=$( … ) || rc=$?`: an `||` context
    # disables `set -e` inside it — the very swallow this test exists to catch.
    local runner="$TEST_TEMP_DIR/install-runner.sh" out rc
    printf '%s\n' '#!/bin/bash' 'set -euo pipefail' \
        'log_command() { shift; "$@"; }' \
        'NODE_VERSION="22.23.4"' 'USERNAME="vscode"' \
        "source \"$block\"" 'echo "REACHED-AFTER-INSTALL"' >"$runner"
    set +e
    out=$(bash "$runner" 2>&1)
    rc=$?
    set -e

    assert_not_equals "0" "$rc" "a failing luggage install exits non-zero"
    assert_not_contains "$out" "REACHED-AFTER-INSTALL" "the script stops at the failed install"
}

# Run node.sh's real install statement against a stub luggage that records
# "$*". Usage: run_install_argv [CONTAINERS_DB] — empty leaves it unset, so the
# script's own default applies. Prints "RC: <status>" then the recorded argv.
run_install_argv() {
    local stub="$TEST_TEMP_DIR/luggage-argv-stub" block="$TEST_TEMP_DIR/install-argv-block.sh"
    local argv_log="$TEST_TEMP_DIR/luggage-argv.log"
    local db_line="unset CONTAINERS_DB"
    [ -n "${1:-}" ] && db_line="export CONTAINERS_DB=\"$1\""
    command rm -f "$argv_log"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s"\n' "$argv_log" >"$stub"
    command chmod +x "$stub"
    _node_install_block "$stub" "$block"

    local runner="$TEST_TEMP_DIR/install-argv-runner.sh" rc
    printf '%s\n' '#!/bin/bash' 'set -euo pipefail' \
        'log_command() { shift; "$@"; }' "$db_line" \
        'NODE_VERSION="22.23.4"' 'USERNAME="vscode"' \
        "source \"$block\"" >"$runner"
    set +e
    bash "$runner" >/dev/null 2>&1
    rc=$?
    set -e

    echo "RC: $rc"
    command cat "$argv_log" 2>/dev/null || echo '<no call>'
}

# Test: the real install statement passes luggage exactly the argv the
# delegation depends on — a dropped `--user` or `--cache-root` passes every
# grep pin, so the assertion is on the whole argv.
test_luggage_install_argv() {
    assert_equals \
        "RC: 0
install node@22.23.4 --catalog /opt/containers-db --user vscode --cache-root /cache --log-dir /var/log/luggage" \
        "$(run_install_argv)" \
        "luggage install receives the exact argv (version, catalog default, user, cache root, log dir)"
}

# Test: a CONTAINERS_DB override reaches luggage's --catalog
test_luggage_install_honors_containers_db() {
    assert_contains "$(run_install_argv "/tmp/alt-containers-db")" \
        "--catalog /tmp/alt-containers-db " "CONTAINERS_DB override reaches --catalog"
}

# Test: a CONTAINERS_DB override reaches luggage resolve too — partials
# must resolve against the same catalog the install reads
test_resolve_honors_containers_db() {
    local out rc=0 argv="$TEST_TEMP_DIR/resolve-argv"
    command rm -f "$argv"
    out=$(
        export CONTAINERS_DB=/tmp/alt-containers-db
        run_version_block "22" "printf '%s\n' \"\$*\" >'$argv'
command cat <<'JSON'
$NODE_RESOLVE_JSON
JSON"
    ) || rc=$?
    assert_equals "0" "$rc" "major-only 22 resolves against the override catalog (exit 0)"
    assert_equals "resolve node --version 22 --catalog /tmp/alt-containers-db --json" \
        "$(command cat "$argv" 2>/dev/null)" "CONTAINERS_DB override reaches luggage resolve's --catalog"
}

# Test: the shared extractor refuses a script with no version block, rather
# than emitting nothing for the fixture and unit suite to source as a no-op
test_extractor_refuses_missing_block() {
    local fake="$TEST_TEMP_DIR/no-block.sh" out rc=0
    printf '#!/bin/bash\nNODE_VERSION=22\n' >"$fake"
    out=$(bash "$PROJECT_ROOT/tests/integration/builds/luggage_node/extract-version-block.sh" \
        "$fake" 2>&1) || rc=$?
    assert_equals "1" "$rc" "extractor exits 1 when node.sh has no version block"
    assert_contains "$out" "no version block found in $fake" "extractor names the script it could not parse"
    assert_not_contains "$out" "never reaches its closing fi" "a blockless script is not reported as unterminated"
}

# Test: the shared extractor refuses a block that never reaches its second
# top-level fi, rather than printing through EOF and handing the fixture and
# unit suite unrelated install code to source as the version block
test_extractor_refuses_unterminated_block() {
    local fake="$TEST_TEMP_DIR/one-fi.sh" out rc=0
    printf '#!/bin/bash\nvalidate_node_version "$NODE_VERSION" || {\n    exit 1\n}\nif true; then\n    :\nfi\nINSTALL_CODE_MARKER=1\n' >"$fake"
    out=$(bash "$PROJECT_ROOT/tests/integration/builds/luggage_node/extract-version-block.sh" \
        "$fake" 2>&1) || rc=$?
    assert_equals "1" "$rc" "extractor exits 1 when the version block has only one top-level fi"
    assert_contains "$out" "version block in $fake never reaches its closing fi" \
        "extractor names the script whose block is unterminated"
    assert_not_contains "$out" "INSTALL_CODE_MARKER" "extractor prints nothing past the partial block"
    assert_not_contains "$out" "no version block found" "an unterminated block is not reported as missing"
}

# Test: an unreadable script is reported as unreadable, not blamed on its
# content as a missing or unterminated block — awk's own fatal-error exit
# must stay distinct from the END sentinel
test_extractor_reports_unreadable_script() {
    local missing="$TEST_TEMP_DIR/does-not-exist.sh" out rc=0
    out=$(bash "$PROJECT_ROOT/tests/integration/builds/luggage_node/extract-version-block.sh" \
        "$missing" 2>&1) || rc=$?
    assert_equals "1" "$rc" "extractor exits 1 when node.sh cannot be read"
    assert_contains "$out" "could not read $missing" "extractor names the unreadable script"
    assert_not_contains "$out" "no version block found" "an unreadable script is not reported as blockless"
    assert_not_contains "$out" "never reaches its closing fi" "an unreadable script is not reported as unterminated"
}

# Test: a luggage path carrying sed-special characters is substituted
# literally, not read as the s### delimiter or the matched-text reference
test_extractor_escapes_luggage_path() {
    local fake="$TEST_TEMP_DIR/two-fi.sh" luggage="$TEST_TEMP_DIR/a&b#c\\d" out rc=0
    printf '#!/bin/bash\nvalidate_node_version "$NODE_VERSION" || {\n    exit 1\n}\nif true; then\n    :\nfi\nif true; then\n    /usr/local/bin/luggage resolve\nfi\nAFTER_BLOCK=1\n' >"$fake"
    out=$(bash "$PROJECT_ROOT/tests/integration/builds/luggage_node/extract-version-block.sh" \
        "$fake" "$luggage" 2>&1) || rc=$?
    assert_equals "0" "$rc" "extractor accepts a luggage path with sed-special characters"
    assert_contains "$out" "    $luggage resolve" "luggage path is substituted verbatim"
    assert_not_contains "$out" "AFTER_BLOCK" "extractor stops at the second top-level fi"
}

# Run security tests
run_test test_no_curl_pipe_bash "node.sh does not use curl | bash pattern"
run_test_with_setup test_node_sh_has_no_inline_install "node.sh has no inline download/verify/extract"
run_test_with_setup test_major_version_resolves_via_luggage "Major-only NODE_VERSION resolves via luggage"
run_test_with_setup test_partial_minor_resolves_via_luggage "Partial NODE_VERSION resolves via luggage"
run_test_with_setup test_exact_version_skips_resolve "Exact NODE_VERSION skips luggage resolve"
run_test_with_setup test_resolve_failure_surfaces_luggage_error "Failed resolve surfaces luggage's error"
run_test_with_setup test_resolve_without_version_fails_closed "Resolve without a version fails closed"
run_test_with_setup test_pre_floor_versions_refused "Node < 18 refused before luggage"
run_test_with_setup test_invalid_version_rejected_by_validation "Malformed NODE_VERSION rejected first"
run_test_with_setup test_luggage_install_failure_aborts "Failing luggage install aborts node.sh"
run_test_with_setup test_luggage_install_argv "luggage install receives the exact argv"
run_test_with_setup test_luggage_install_honors_containers_db "CONTAINERS_DB reaches luggage --catalog"
run_test_with_setup test_resolve_honors_containers_db "CONTAINERS_DB reaches luggage resolve --catalog"
run_test_with_setup test_extractor_refuses_missing_block "Version-block extractor refuses a script without one"
run_test_with_setup test_extractor_refuses_unterminated_block "Version-block extractor refuses a block missing its closing fi"
run_test_with_setup test_extractor_reports_unreadable_script "Version-block extractor reports an unreadable script as unreadable"
run_test_with_setup test_extractor_escapes_luggage_path "Version-block extractor substitutes a sed-special luggage path verbatim"

# Generate test report
generate_report
