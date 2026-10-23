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

# Run golang.sh's real post-install section — cache dirs, the bashrc.d
# writes, the startup script, and test-go — with its build-time and absolute
# targets redirected under TEST_TEMP_DIR (#1346). The section is extracted
# from the script, not copied, and reads the real lib/ content files, so these
# tests break when golang.sh changes what it configures. luggage's own install
# end-state is asserted in a real image by test_luggage_golang.sh.
# Usage: run_config_section
# Leaves the installed tree under $TEST_TEMP_DIR/root and the
# create_cache_directories argv in $TEST_TEMP_DIR/cache-dirs.log.
run_config_section() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"
    local root="$TEST_TEMP_DIR/root" section="$TEST_TEMP_DIR/config-section.sh"

    command mkdir -p "$root/usr/local/bin"
    command awk '/^# Cache and Path Configuration/{f=1} /^# Final Verification/{exit} f{print}' "$golang_script" |
        command sed -e "s#/tmp/build-scripts#$PROJECT_ROOT/lib#g" \
            -e "s#/etc/#$root/etc/#g" \
            -e "s#/usr/local/bin/test-go#$root/usr/local/bin/test-go#g" >"$section"
    # A renamed section marker extracts nothing, and sourcing an empty file is
    # a silent no-op: fail here, by name, not later on a missing output.
    if [ ! -s "$section" ]; then
        assert_true false "no '# Cache and Path Configuration' section found in $golang_script"
        return 1
    fi

    # A command in the section failing must FAIL the test, not return quietly:
    # a test that exits 0 with no assertion counts as a pass. Run it as its own
    # bash process — a `( set -e; … )` subshell on the left of `||` runs with
    # errexit suspended, so a failing command would never stop it.
    local err="$TEST_TEMP_DIR/config-section.err" rc=0
    # shellcheck disable=SC2016  # expanded by the inner bash, not here
    bash -c '
        set -euo pipefail
        log_message() { :; }
        log_command() {
            shift
            "$@" >/dev/null
        }
        cache_log="$3"
        create_cache_directories() { printf "%s\n" "$@" >"$cache_log"; }
        source "$1"
        source "$2"
    ' _ "$PROJECT_ROOT/lib/base/bashrc-helpers.sh" "$section" "$TEST_TEMP_DIR/cache-dirs.log" \
        >/dev/null 2>"$err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        assert_true false "golang.sh config section failed (rc=$rc): $(command cat "$err")"
        return 1
    fi
}

# Source the generated 50-golang.sh in a clean interactive shell (its env
# block returns early when non-interactive) and run a probe command there.
# Usage: probe_bashrc <command>
probe_bashrc() {
    env -i HOME="$TEST_TEMP_DIR" PATH=/usr/bin:/bin \
        bash --norc -i -c "source '$TEST_TEMP_DIR/root/etc/bashrc.d/50-golang.sh'; $1" 2>/dev/null
}

# Test: GOPATH's workspace subdirectories are created under /cache/go
test_cache_dirs_created() {
    run_config_section || return 0
    assert_equals "/cache/go/bin
/cache/go/src
/cache/go/pkg" "$(command cat "$TEST_TEMP_DIR/cache-dirs.log" 2>/dev/null || echo '<no call>')" \
        "create_cache_directories receives /cache/go/{bin,src,pkg}"
}

# Test: the shipped bashrc exports the layout golang.sh itself configures
test_bashrc_env_matches_script() {
    run_config_section || return 0
    local out
    out=$(probe_bashrc 'printf "%s|" "$GOROOT" "$GOPATH" "$GOCACHE" "$GOMODCACHE" "$GO111MODULE" "$GOPROXY" "$GOSUMDB"')
    assert_equals "/usr/local/go|/cache/go|/cache/go-build|/cache/go-mod|on|https://proxy.golang.org,direct|sum.golang.org|" \
        "$out" "50-golang.sh exports GOROOT/GOPATH/GOCACHE/GOMODCACHE/GO111MODULE/GOPROXY/GOSUMDB"

    local path
    path=$(probe_bashrc 'echo ":$PATH:"')
    assert_contains "$path" ":/usr/local/go/bin:" "PATH gains GOROOT/bin"
    assert_contains "$path" ":/cache/go/bin:" "PATH gains GOPATH/bin"
}

# Test: the shipped bashrc defines the aliases and helper functions
test_bashrc_aliases_loaded() {
    run_config_section || return 0
    local out
    out=$(probe_bashrc 'alias gob; alias gomt; type -t go-init; type -t go-cover')
    assert_contains "$out" "alias gob='go build'" "gob alias defined"
    assert_contains "$out" "alias gomt='go mod tidy'" "gomt alias defined"
    assert_equals "2" "$(printf '%s\n' "$out" | command grep -cx 'function')" \
        "go-init and go-cover are defined as functions"
}

# Test: the startup and verification scripts are installed executable,
# byte-identical to their lib/ sources
test_startup_and_verify_scripts_installed() {
    run_config_section || return 0
    local root="$TEST_TEMP_DIR/root" pair dest src
    for pair in "etc/container/first-startup/30-go-setup.sh:30-go-setup.sh" \
        "usr/local/bin/test-go:test-go.sh"; do
        dest="$root/${pair%%:*}"
        src="$PROJECT_ROOT/lib/features/lib/golang/${pair##*:}"
        assert_equals "755" "$(command stat -c %a "$dest" 2>/dev/null || echo missing)" \
            "${pair%%:*} installed mode 755"
        if command cmp -s "$src" "$dest"; then
            assert_true true "${pair%%:*} matches lib/features/lib/golang/${pair##*:}"
        else
            assert_true false "${pair%%:*} differs from (or is missing vs) its lib/ source"
        fi
    done
}

# golang.sh delegates the Go install to `luggage install` (#811): arch
# selection, download, tier-3 verification, extraction, and the go/gofmt
# links all live in the luggage engine and the containers-db catalog now.
# The tests below run golang.sh's real version block and install statement
# against a stub luggage; tests/integration/builds/test_luggage_golang.sh runs
# them against the real engine.

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
    # The same extractor the luggage_golang fixture runs against real luggage
    # output, here with luggage's absolute path redirected to the stub.
    bash "$PROJECT_ROOT/tests/integration/builds/luggage_golang/extract-version-block.sh" \
        "$golang_script" "$stub" >"$block"

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
        GO_VERSION="$2"
        source "$3"
        echo "RESULT: $GO_VERSION"
    ' _ "$PROJECT_ROOT/lib/base/version-validation.sh" "$go_version" "$block"
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

# Run golang.sh's real install statement against a stub luggage that records
# "$*" and succeeds. Usage: run_install_argv [CONTAINERS_DB] [USERNAME] — an
# empty or missing CONTAINERS_DB leaves it unset, so the script's own default
# applies; USERNAME defaults to vscode.
# Prints "RC: <status>" then the recorded argv (or "<no call>").
run_install_argv() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"
    local stub="$TEST_TEMP_DIR/luggage-argv-stub" block="$TEST_TEMP_DIR/install-argv-block.sh"
    local argv_log="$TEST_TEMP_DIR/luggage-argv.log"
    local db_line="unset CONTAINERS_DB" user="${2:-vscode}"
    [ -n "${1:-}" ] && db_line="export CONTAINERS_DB=\"$1\""
    command rm -f "$argv_log"
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
$db_line
GO_VERSION="1.27.2"
USERNAME="$user"
# shellcheck disable=SC1091
source "$block"
EOF
    set +e
    bash "$runner" >/dev/null 2>&1
    rc=$?
    set -e

    echo "RC: $rc"
    command cat "$argv_log" 2>/dev/null || echo '<no call>'
}

# Test: the real install statement passes luggage exactly the arguments the
# delegation depends on. golang.sh no longer creates or chowns the cache dirs
# itself, so a dropped `--user` leaves them root-owned and a dropped
# `--cache-root` puts them in luggage's default — both pass every grep pin.
# The assertion is on the whole argv.
test_luggage_install_argv() {
    local out
    out=$(run_install_argv)

    assert_equals \
        "RC: 0
install go@1.27.2 --catalog /opt/containers-db --user vscode --cache-root /cache --log-dir /var/log/luggage" \
        "$out" \
        "luggage install receives the exact argv (version, catalog default, user, cache root, log dir)"
}

# Test: a CONTAINERS_DB override reaches luggage's --catalog. Catches a catalog
# path hard-coded to the default, which the unset case above cannot tell apart.
test_luggage_install_honors_containers_db() {
    local out
    out=$(run_install_argv "/tmp/alt-containers-db")

    assert_equals \
        "RC: 0
install go@1.27.2 --catalog /tmp/alt-containers-db --user vscode --cache-root /cache --log-dir /var/log/luggage" \
        "$out" \
        "CONTAINERS_DB override is passed as luggage's --catalog"
}

# Test: a non-default USERNAME reaches luggage's --user. Catches a user
# hard-coded to vscode, which the default case above cannot tell apart.
test_luggage_install_honors_username() {
    local out
    out=$(run_install_argv "" "builder")

    assert_equals \
        "RC: 0
install go@1.27.2 --catalog /opt/containers-db --user builder --cache-root /cache --log-dir /var/log/luggage" \
        "$out" \
        "USERNAME is passed as luggage's --user"
}

# Test: the shared extractor refuses a script with no version block, rather
# than emitting nothing for the fixture and unit suite to source as a no-op
test_extractor_refuses_missing_block() {
    local fake="$TEST_TEMP_DIR/no-block.sh" out rc=0
    printf '#!/bin/bash\nGO_VERSION=1.26\n' >"$fake"
    out=$(bash "$PROJECT_ROOT/tests/integration/builds/luggage_golang/extract-version-block.sh" \
        "$fake" 2>&1) || rc=$?
    assert_equals "1" "$rc" "extractor exits 1 when golang.sh has no version block"
    assert_contains "$out" "no version block found in $fake" "extractor names the script it could not parse"
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

# Test: partial versions resolve against the catalog, not upstream — the old
# upstream resolver must not linger beside the luggage resolve
test_no_upstream_version_resolution() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"

    if command grep -q 'resolve_go_version' "$golang_script"; then
        assert_true false "Still resolves versions upstream via resolve_go_version"
    else
        assert_true true "No upstream version resolution"
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
run_test_with_setup test_cache_dirs_created "GOPATH workspace dirs are created under /cache/go"
run_test_with_setup test_bashrc_env_matches_script "Shipped bashrc exports golang.sh's cache layout"
run_test_with_setup test_bashrc_aliases_loaded "Shipped bashrc defines Go aliases and helpers"
run_test_with_setup test_startup_and_verify_scripts_installed "Startup and test-go scripts are installed"
run_test_with_setup test_luggage_install_failure_aborts "luggage install failure is not swallowed"
run_test_with_setup test_luggage_install_argv "luggage install receives the exact argv"
run_test_with_setup test_luggage_install_honors_containers_db "CONTAINERS_DB override reaches luggage --catalog"
run_test_with_setup test_luggage_install_honors_username "USERNAME override reaches luggage --user"
run_test_with_setup test_partial_version_resolves_to_top_level_version "Partial pin resolves to the top-level version"
run_test_with_setup test_resolve_parses_last_key_without_comma "Resolve parses a version with no trailing comma"
run_test_with_setup test_exact_version_skips_resolve "Exact pin skips resolution"
run_test_with_setup test_resolve_failure_surfaces_luggage_error "Failed resolve surfaces luggage's error"
run_test_with_setup test_resolve_without_version_fails_closed "Resolve output without a version fails closed"
run_test_with_setup test_pre_floor_versions_refused "Go below 1.22 is refused up front"
run_test_with_setup test_bare_major_rejected_by_validation "Bare major GO_VERSION is rejected by validation"
run_test_with_setup test_non_1x_major_reaches_resolve "Non-1.x partial reaches resolve"
run_test_with_setup test_extractor_refuses_missing_block "Version-block extractor refuses a script without one"
run_test_with_setup test_no_inline_go_install "No inline Go download/verify/extract remains"
run_test_with_setup test_no_upstream_version_resolution "No upstream resolve_go_version remains"

# Generate test report
generate_report
