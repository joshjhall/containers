#!/usr/bin/env bash
# Unit tests for lib/features/golang.sh
# Tests Go installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Golang Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-golang-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export GO_VERSION="1.24.5"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local"
    mkdir -p "$TEST_TEMP_DIR/home/testuser"
    mkdir -p "$TEST_TEMP_DIR/cache/go"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset GO_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Go version parsing
test_go_version_parsing() {
    # Test version extraction
    local version="1.24.5"
    local major
    major=$(echo $version | command cut -d. -f1)
    local minor
    minor=$(echo $version | command cut -d. -f2)
    local patch
    patch=$(echo $version | command cut -d. -f3)

    assert_equals "1" "$major" "Major version extracted correctly"
    assert_equals "24" "$minor" "Minor version extracted correctly"
    assert_equals "5" "$patch" "Patch version extracted correctly"

    # Test version comparison logic
    if [ "$major" -ge 1 ] && [ "$minor" -ge 11 ]; then
        assert_true true "Version supports modules (>= 1.11)"
    else
        assert_true false "Version too old for modules"
    fi
}

# Test: Go installation directory structure
test_go_installation_structure() {
    local go_root="$TEST_TEMP_DIR/usr/local/go"

    # Create mock Go installation
    mkdir -p "$go_root/bin"
    mkdir -p "$go_root/src"
    mkdir -p "$go_root/pkg"

    # Create mock Go binaries
    touch "$go_root/bin/go"
    touch "$go_root/bin/gofmt"
    chmod +x "$go_root/bin/go" "$go_root/bin/gofmt"

    # Check structure
    assert_dir_exists "$go_root"
    assert_dir_exists "$go_root/bin"
    assert_file_exists "$go_root/bin/go"
    assert_file_exists "$go_root/bin/gofmt"

    # Check executables
    if [ -x "$go_root/bin/go" ]; then
        assert_true true "go binary is executable"
    else
        assert_true false "go binary is not executable"
    fi
}

# Test: GOPATH configuration
test_gopath_configuration() {
    # Test with cache directory
    local cache_dir="$TEST_TEMP_DIR/cache"
    if [ -d "$cache_dir" ]; then
        local expected_gopath="$cache_dir/go"
        assert_not_empty "$expected_gopath" "GOPATH uses cache directory when available"
    fi

    # Test fallback to home directory
    local home_gopath="$TEST_TEMP_DIR/home/testuser/go"
    mkdir -p "$home_gopath"
    assert_dir_exists "$home_gopath"

    # Check GOPATH subdirectories
    mkdir -p "$home_gopath/bin"
    mkdir -p "$home_gopath/src"
    mkdir -p "$home_gopath/pkg"

    assert_dir_exists "$home_gopath/bin"
    assert_dir_exists "$home_gopath/src"
    assert_dir_exists "$home_gopath/pkg"
}

# Test: Go environment variables
test_go_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-golang.sh"

    # Create mock bashrc content
    command cat >"$bashrc_file" <<'EOF'
export GOROOT="/usr/local/go"
export GOPATH="${GOPATH:-/cache/go}"
export GOCACHE="${GOCACHE:-$GOPATH/cache}"
export GOMODCACHE="${GOMODCACHE:-$GOPATH/pkg/mod}"
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
export GO111MODULE=on
EOF

    # Check environment variables
    if command grep -q "export GOROOT=" "$bashrc_file"; then
        assert_true true "GOROOT is exported"
    else
        assert_true false "GOROOT is not exported"
    fi

    if command grep -q "export GOPATH=" "$bashrc_file"; then
        assert_true true "GOPATH is exported"
    else
        assert_true false "GOPATH is not exported"
    fi

    if command grep -q "export GO111MODULE=on" "$bashrc_file"; then
        assert_true true "GO111MODULE is enabled"
    else
        assert_true false "GO111MODULE is not enabled"
    fi

    # Check PATH includes Go directories
    if command grep -q 'PATH.*GOROOT/bin.*GOPATH/bin' "$bashrc_file"; then
        assert_true true "PATH includes Go binary directories"
    else
        assert_true false "PATH doesn't include Go directories"
    fi
}

# Test: Go cache configuration
test_go_cache_configuration() {
    local cache_base="$TEST_TEMP_DIR/cache/go"

    # Create cache directories
    mkdir -p "$cache_base/cache"
    mkdir -p "$cache_base/pkg/mod"

    assert_dir_exists "$cache_base/cache"
    assert_dir_exists "$cache_base/pkg/mod"

    # Check cache environment would be set
    local gocache="$cache_base/cache"
    local gomodcache="$cache_base/pkg/mod"

    assert_not_empty "$gocache" "GOCACHE path is set"
    assert_not_empty "$gomodcache" "GOMODCACHE path is set"
}

# Test: Go workspace permissions
test_go_workspace_permissions() {
    local gopath="$TEST_TEMP_DIR/home/testuser/go"
    mkdir -p "$gopath"

    # Simulate setting ownership
    # In real script: chown -R ${USER_UID}:${USER_GID} "$gopath"

    # Check directory exists and is accessible
    if [ -d "$gopath" ] && [ -w "$gopath" ]; then
        assert_true true "Go workspace is writable"
    else
        assert_true false "Go workspace is not writable"
    fi
}

# Test: Go aliases and helpers
test_go_aliases_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-golang.sh"

    # Add aliases section
    command cat >>"$bashrc_file" <<'EOF'

# Go aliases
alias gotest='go test -v ./...'
alias gomod='go mod'
alias gofmtall='gofmt -s -w .'
alias govet='go vet ./...'
EOF

    # Check aliases
    if command grep -q "alias gotest=" "$bashrc_file"; then
        assert_true true "gotest alias defined"
    else
        assert_true false "gotest alias not defined"
    fi

    if command grep -q "alias gomod=" "$bashrc_file"; then
        assert_true true "gomod alias defined"
    else
        assert_true false "gomod alias not defined"
    fi
}

# golang.sh delegates the Go install to `luggage install` (#811): arch
# selection, download, tier-3 verification, extraction, and the go/gofmt
# links all live in the luggage engine and the containers-db catalog now.
# These pin the delegation shape; tests/integration/builds/
# test_luggage_golang.sh is the behavioral check.

# Test: golang.sh installs Go through luggage, against the default catalog
test_luggage_invocation() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"

    if command grep -qE '/usr/local/bin/luggage install "go@\$\{GO_VERSION\}"' "$golang_script"; then
        assert_true true "golang.sh invokes /usr/local/bin/luggage install go@\${GO_VERSION}"
    else
        assert_true false "golang.sh does not invoke luggage install for go"
    fi

    if command grep -q 'CONTAINERS_DB:-/opt/containers-db' "$golang_script"; then
        assert_true true "luggage call defaults to /opt/containers-db catalog"
    else
        assert_true false "luggage call missing /opt/containers-db default"
    fi
}

# Test: partial versions resolve against the catalog, not upstream
test_partial_version_resolves_via_catalog() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"

    if command grep -q '/usr/local/bin/luggage resolve go' "$golang_script"; then
        assert_true true "Partial GO_VERSION resolves via luggage resolve go"
    else
        assert_true false "Partial GO_VERSION not resolved via luggage resolve go"
    fi

    if command grep -q 'resolve_go_version' "$golang_script"; then
        assert_true false "Still resolves versions upstream via resolve_go_version"
    else
        assert_true true "No upstream version resolution"
    fi
}

# Run golang.sh's real version block — input validation, the pre-1.22 floor,
# and the partial resolve — against a stub luggage, and print what it decided.
# Extracting the block from the script (not copying it) and sourcing the real
# version-validation.sh keeps these tests on the code that ships, entry check
# included. Usage: run_version_block <GO_VERSION> <stub-luggage-body>
# Prints "RESULT: <version>" on success, the logged errors on failure, and
# returns the block's exit status.
run_version_block() {
    local go_version="$1" stub_body="$2"
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"
    local stub="$TEST_TEMP_DIR/luggage-stub" block="$TEST_TEMP_DIR/version-block.sh"

    printf '#!/bin/bash\n%s\n' "$stub_body" >"$stub"
    command chmod +x "$stub"
    # From input validation through the resolve block's closing `fi` (the
    # second top-level `fi`; validation uses `|| { }`, not if/fi), with
    # luggage's absolute path redirected.
    command awk '/^validate_go_version /{f=1} f{print} f && /^fi$/ && ++n==2{exit}' "$golang_script" |
        command sed "s#/usr/local/bin/luggage#$stub#g" >"$block"

    (
        set -euo pipefail
        log_error() { echo "ERR: $*"; }
        log_message() { :; }
        # shellcheck disable=SC1091
        source "$PROJECT_ROOT/lib/base/version-validation.sh"
        GO_VERSION="$go_version"
        # shellcheck disable=SC1090
        source "$block"
        echo "RESULT: $GO_VERSION"
    )
}

# luggage resolve --json, as it really pretty-prints: two-space indent and the
# top-level version mid-object. The decoy is a dependency carrying its own
# `"version": "…"` key (Dependency.version is a real optional field), printed
# FIRST at a deeper indent: an unanchored match would take "9.9.9". The
# version_args element is a bare string and could never match, so it is not
# the decoy that matters.
LUGGAGE_RESOLVE_JSON='{
  "tool": "go",
  "dependencies": [
    {
      "tool": "ca_certificates",
      "version": "9.9.9"
    }
  ],
  "version": "1.26.10",
  "version_args": [
    "version"
  ],
  "method_name": "go-tarball"
}'

# Test: a partial pin resolves through luggage to the catalog's newest patch
test_partial_version_resolves_to_top_level_version() {
    local out rc=0
    out=$(run_version_block "1.26" "cat <<'JSON'
$LUGGAGE_RESOLVE_JSON
JSON") || rc=$?
    assert_equals "0" "$rc" "partial 1.26 resolves (exit 0)"
    assert_contains "$out" "RESULT: 1.26.10" "resolves to the top-level version, not the nested version_args element"
}

# Test: the top-level version is found whether or not a trailing comma follows
test_resolve_parses_last_key_without_comma() {
    local out rc=0
    out=$(run_version_block "1.26" "cat <<'JSON'
{
  \"tool\": \"go\",
  \"version\": \"1.26.9\"
}
JSON") || rc=$?
    assert_equals "0" "$rc" "version as the last key (no trailing comma) still parses"
    assert_contains "$out" "RESULT: 1.26.9" "parsed 1.26.9"
}

# Test: an exact pin skips resolution entirely (luggage must not be called)
test_exact_version_skips_resolve() {
    local out rc=0
    out=$(run_version_block "1.27.2" 'echo "luggage must not be called for an exact pin" >&2; exit 99') || rc=$?
    assert_equals "0" "$rc" "exact 1.27.2 passes through"
    assert_contains "$out" "RESULT: 1.27.2" "exact version unchanged"
}

# Test: a failing luggage resolve fails the build and surfaces luggage's reason
test_resolve_failure_surfaces_luggage_error() {
    local out rc=0
    out=$(run_version_block "1.30" 'echo "error: no version of `go` matches spec `partial:1.30`" >&2; exit 1') || rc=$?
    assert_not_equals "0" "$rc" "a failed resolve exits non-zero"
    assert_contains "$out" "Could not resolve Go 1.30" "names the request"
    assert_contains "$out" "partial:1.30" "carries luggage's own stderr, not a guessed cause"
}

# Test: luggage succeeding with no top-level version is an error, not ""
test_resolve_without_version_fails_closed() {
    local out rc=0
    out=$(run_version_block "1.26" "cat <<'JSON'
{
  \"tool\": \"go\",
  \"version_args\": [
    \"version\"
  ]
}
JSON") || rc=$?
    assert_not_equals "0" "$rc" "no top-level version exits non-zero"
    assert_contains "$out" "carried no top-level version" "fails closed instead of installing go@\"\""
}

# Test: Go < 1.22 is refused up front, in both partial and exact form
test_pre_floor_versions_refused() {
    local v out rc
    for v in 1.21 1.21.5; do
        rc=0
        out=$(run_version_block "$v" 'echo "luggage must not be reached below the floor" >&2; exit 99') || rc=$?
        assert_not_equals "0" "$rc" "Go $v is refused"
        assert_contains "$out" "starts at 1.22.0" "Go $v refusal names the catalog floor"
    done
    # The floor itself is accepted.
    rc=0
    out=$(run_version_block "1.22.0" 'exit 99') || rc=$?
    assert_equals "0" "$rc" "Go 1.22.0 (the floor) is accepted"
}

# Test: a bare major ("1") never reaches the floor check. `cut -d. -f2` would
# return the whole string for it and misread "1" as minor 1 — so this pins
# that input validation (which requires X.Y) rejects it first, by its own
# message rather than the floor's.
test_bare_major_rejected_by_validation() {
    local out rc=0
    out=$(run_version_block "1" 'echo "luggage must not be reached" >&2; exit 99') || rc=$?
    assert_not_equals "0" "$rc" "GO_VERSION=1 is rejected"
    assert_contains "$out" "Invalid GO_VERSION format" "rejected by input validation"
    assert_not_contains "$out" "starts at 1.22.0" "not misreported as below the catalog floor"
}

# Test: the floor is a 1.x rule — a future 2.x partial is not refused by it
# and goes on to luggage, which owns whether that version exists.
test_non_1x_major_reaches_resolve() {
    local out rc=0
    out=$(run_version_block "2.0" 'echo "error: no version of `go` matches spec `partial:2.0`" >&2; exit 1') || rc=$?
    assert_not_contains "$out" "starts at 1.22.0" "2.0 is not caught by the 1.x floor"
    assert_contains "$out" "partial:2.0" "2.0 reached luggage resolve"
}

# Test: a failing luggage install aborts the feature script. Runs the real
# install statement, exactly as written in golang.sh, under the script's own
# `set -euo pipefail`, with a luggage stub that exits 1 — then checks that the
# line after it never ran. That catches every way of swallowing the failure
# (`|| true`, `|| :`, `|| echo`, wrapping it in an `if`), not just one spelling.
# log_command is stubbed to run its command and return that command's status,
# which is what the real one does (it reads ${PIPESTATUS[0]}).
test_luggage_install_failure_aborts() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"
    local stub="$TEST_TEMP_DIR/luggage-fail-stub" block="$TEST_TEMP_DIR/install-block.sh"
    printf '#!/bin/bash\necho "stub luggage: install failed" >&2\nexit 1\n' >"$stub"
    command chmod +x "$stub"

    # The install call spans several continuation lines; take the block from
    # the log_command line through the first line that does not continue.
    command awk '/log_command "luggage install go@/{f=1} f{print; if ($0 !~ /\\$/) exit}' "$golang_script" |
        command sed "s#/usr/local/bin/luggage#$stub#g" >"$block"

    if [ ! -s "$block" ]; then
        assert_true false "Could not locate the luggage install block"
        return
    fi

    # Run it as its own bash process. NOT `out=$( ... ) || rc=$?`: that puts the
    # subshell in an `||` context, where bash disables `set -e` for everything
    # inside it — the very swallow this test exists to catch, applied to the
    # test itself.
    local runner="$TEST_TEMP_DIR/install-runner.sh" out rc
    command cat >"$runner" <<EOF
#!/bin/bash
set -euo pipefail
log_command() {
    shift
    "\$@"
}
GO_VERSION="1.27.2"
USERNAME="vscode"
# shellcheck disable=SC1091
source "$block"
echo "REACHED-AFTER-INSTALL"
EOF
    set +e
    out=$(bash "$runner" 2>&1)
    rc=$?
    set -e

    assert_not_equals "0" "$rc" "a failing luggage install exits non-zero"
    assert_not_contains "$out" "REACHED-AFTER-INSTALL" "the script stops at the failed install"
}

# Test: the real install statement passes luggage exactly the arguments the
# delegation depends on. golang.sh no longer creates or chowns the cache dirs
# itself, so a dropped `--user` leaves them root-owned and a dropped
# `--cache-root` puts them in luggage's default — both pass every grep pin.
# The stub records "$*" and succeeds; the assertion is on the whole argv.
test_luggage_install_argv() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"
    local stub="$TEST_TEMP_DIR/luggage-argv-stub" block="$TEST_TEMP_DIR/install-argv-block.sh"
    local argv_log="$TEST_TEMP_DIR/luggage-argv.log"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s"\n' "$argv_log" >"$stub"
    command chmod +x "$stub"

    command awk '/log_command "luggage install go@/{f=1} f{print; if ($0 !~ /\\$/) exit}' "$golang_script" |
        command sed "s#/usr/local/bin/luggage#$stub#g" >"$block"

    local runner="$TEST_TEMP_DIR/install-argv-runner.sh" rc
    command cat >"$runner" <<EOF
#!/bin/bash
set -euo pipefail
log_command() {
    shift
    "\$@"
}
unset CONTAINERS_DB
GO_VERSION="1.27.2"
USERNAME="vscode"
# shellcheck disable=SC1091
source "$block"
EOF
    set +e
    bash "$runner" >/dev/null 2>&1
    rc=$?
    set -e

    assert_equals "0" "$rc" "install block runs against a succeeding stub"
    assert_equals \
        "install go@1.27.2 --catalog /opt/containers-db --user vscode --cache-root /cache --log-dir /var/log/luggage" \
        "$(command cat "$argv_log" 2>/dev/null || echo '<no call>')" \
        "luggage install receives the exact argv (version, catalog default, user, cache root, log dir)"
}

# Test: Go module proxy configuration
test_go_module_proxy() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-golang.sh"

    # Add proxy configuration
    command cat >>"$bashrc_file" <<'EOF'

# Go module proxy (optional, improves download speed)
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.org}"
EOF

    # Check proxy settings
    if command grep -q "export GOPROXY=" "$bashrc_file"; then
        assert_true true "GOPROXY is configured"
    else
        assert_true false "GOPROXY is not configured"
    fi

    if command grep -q "export GOSUMDB=" "$bashrc_file"; then
        assert_true true "GOSUMDB is configured"
    else
        assert_true false "GOSUMDB is not configured"
    fi
}

# Test: Go verification
test_go_verification() {
    local test_script="$TEST_TEMP_DIR/test-go.sh"

    # Create verification script
    command cat >"$test_script" <<'EOF'
#!/bin/bash
echo "Go version:"
go version 2>/dev/null || echo "Go not installed"
echo "GOPATH: ${GOPATH:-not set}"
echo "GOROOT: ${GOROOT:-not set}"
echo "Go env:"
go env GOPATH GOROOT GOCACHE 2>/dev/null || echo "Unable to get Go env"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Test: the inline download/verify/extract path is gone — luggage owns it.
# A leftover would mean two installers racing over /usr/local/go.
test_no_inline_go_install() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"
    local leftover

    leftover=$(command grep -nE 'verify_download|checksum-fetch\.sh|checksum-verification\.sh|download-verify\.sh|version-resolution\.sh|curl .*go\.dev|tar -x' "$golang_script" || true)
    if [ -n "$leftover" ]; then
        assert_true false "Inline Go install path remains: $leftover"
    else
        assert_true true "No inline download/verify/extract left in golang.sh"
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
run_test_with_setup test_go_version_parsing "Go version parsing works correctly"
run_test_with_setup test_go_installation_structure "Go installation structure is correct"
run_test_with_setup test_gopath_configuration "GOPATH configuration is proper"
run_test_with_setup test_go_environment_variables "Go environment variables are set"
run_test_with_setup test_go_cache_configuration "Go cache is configured correctly"
run_test_with_setup test_go_workspace_permissions "Go workspace has correct permissions"
run_test_with_setup test_go_aliases_helpers "Go aliases and helpers are defined"
run_test_with_setup test_luggage_invocation "golang.sh delegates the Go install to luggage"
run_test_with_setup test_partial_version_resolves_via_catalog "Partial GO_VERSION resolves via the luggage catalog"
run_test_with_setup test_luggage_install_failure_aborts "luggage install failure is not swallowed"
run_test_with_setup test_luggage_install_argv "luggage install receives the exact argv"
run_test_with_setup test_partial_version_resolves_to_top_level_version "Partial pin resolves to the top-level version"
run_test_with_setup test_resolve_parses_last_key_without_comma "Resolve parses a version with no trailing comma"
run_test_with_setup test_exact_version_skips_resolve "Exact pin skips resolution"
run_test_with_setup test_resolve_failure_surfaces_luggage_error "Failed resolve surfaces luggage's error"
run_test_with_setup test_resolve_without_version_fails_closed "Resolve output without a version fails closed"
run_test_with_setup test_pre_floor_versions_refused "Go below 1.22 is refused up front"
run_test_with_setup test_bare_major_rejected_by_validation "Bare major GO_VERSION is rejected by validation"
run_test_with_setup test_non_1x_major_reaches_resolve "Non-1.x partial reaches resolve"
run_test_with_setup test_go_module_proxy "Go module proxy is configured"
run_test_with_setup test_go_verification "Go verification script works"
run_test_with_setup test_no_inline_go_install "No inline Go download/verify/extract remains"

# Generate test report
generate_report
