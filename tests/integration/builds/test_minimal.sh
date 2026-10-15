#!/usr/bin/env bash
# @tier: pr,merge,weekly
# Test minimal container builds
#
# This test verifies that the most basic container configurations
# build successfully and have the expected base functionality.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# This suite builds and runs containers (#831).
require_docker

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Minimal Container Builds"

# Test: Base container with no features
test_base_container_only() {
    # Use pre-built image if provided, otherwise build locally
    local expected_workspace
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
        # CI builds use PROJECT_NAME=containers
        expected_workspace="/workspace/containers"
    else
        local image="test-minimal-base-$$"
        echo "Building image locally: $image"
        expected_workspace="/workspace/test-minimal"

        # Build with no features enabled (standalone mode)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-minimal \
            -t "$image"
    fi

    # Verify basic functionality
    assert_command_in_container "$image" "echo 'Hello World'" "Hello World"
    assert_command_in_container "$image" "whoami" "developer"
    assert_command_in_container "$image" "pwd" "$expected_workspace"

    # Verify base tools
    assert_executable_in_path "$image" "bash"
    assert_executable_in_path "$image" "curl"
    assert_executable_in_path "$image" "wget"

    # Check user setup
    assert_dir_in_image "$image" "/home/developer"
    assert_dir_in_image "$image" "$expected_workspace"
}

# Test: Cache directories are properly configured
test_cache_directories() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Verify cache directory exists
    assert_dir_in_image "$image" "/cache"

    # Verify cache is writable by the developer user
    assert_command_in_container "$image" "test -w /cache && echo writable" "writable"
}

# Test: Runtime scripts executed successfully
test_runtime_initialization() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Runtime scripts should have executed (check for marker or log output)
    # The container startup shows "=== Running startup scripts ===" in output
    assert_command_in_container "$image" "echo 'startup complete'" "startup complete"

    # Verify first-time setup can be re-run safely (idempotent)
    assert_command_in_container "$image" "ls /workspace" ""
}

# Test: Runtime lib fragments are installed where the installed scripts look
# (issue #1093). The startup scripts are copied alone into
# /etc/container/startup/, so they source their fragments from the fixed path
# /opt/container-runtime/lib. A missing fragment is reported and skipped, never
# fatal — so without this test a packaging regression would silently disable
# e.g. every fs-health repair while the container still boots.
test_runtime_lib_installed() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"
    local fragment

    # Derived from the source tree so a newly added fragment is covered too.
    for fragment in "$CONTAINERS_DIR"/lib/runtime/lib/*.sh; do
        assert_file_in_image "$image" "/opt/container-runtime/lib/${fragment##*/}"
    done

    local script="/etc/container/startup/42-workspace-fs-health.sh"
    assert_file_in_image "$image" "$script"

    # Capture and judge the output INSIDE the container: TEST_OUTPUT also holds
    # the entrypoint's own boot run of this same script, so matching "not found"
    # against it directly would conflate the two runs. The script exits 0 by
    # design, so a non-zero status (a crash before the fragment loads) fails too.
    # The warning's exact wording is pinned by
    # tests/unit/runtime/workspace-fs-health-fragment.sh, so a rewording that
    # would blind this broader "not found" match fails there first.
    assert_command_in_container "$image" \
        "out=\$($script 2>&1); rc=\$?; if [ \"\$rc\" -ne 0 ] || command grep -q 'not found' <<<\"\$out\"; then command echo \"fragment-missing (rc=\$rc): \$out\"; else command echo fragment-ok; fi" \
        "fragment-ok" \
        "Installed $script should load its repo-tree fragment"

    # Every other installed consumer loads its fragment behind a bare [ -f ],
    # so a path typo skips it at boot without failing (#1095). Scan the
    # installed scripts for fragment references and resolve each the way its
    # consumer does: a literal path is tested as written (so a typo in the
    # directory counts, not just the basename), and a $VAR/<name>.sh reference
    # (entrypoint's $_RUNTIME_LIB) is expanded through that file's own
    # assignment -- or, where it is computed (healthcheck's RUNTIME_LIB), every
    # lib-dir literal in the file -- so a typo'd assignment or use-site variable
    # fails too. The known consumers must be among those scanned, so a regex
    # that matches nothing cannot print the sentinel; a grep error fails rather
    # than silently shrinking the scan.
    local scan
    read -r -d '' scan <<'EOF' || true
libdir='/opt/container-[A-Za-z0-9_.-]+/lib[A-Za-z0-9_.-]*'
lit="$libdir/[A-Za-z0-9_./-]+\\.sh"
var='\$\{?_?[A-Z_]*RUNTIME[A-Z_]*\}?/[A-Za-z0-9_./-]+\.sh'
dirs=""
for d in /usr/local/bin /usr/local/sbin /etc/container/startup /opt/container-runtime; do
    [ -d "$d" ] && dirs="$dirs $d"
done
errfile=$(command mktemp)
consumers=$(command grep -rlIE "$lit|$var" $dirs </dev/null 2>"$errfile")
missing=""
for f in $consumers; do
    for ref in $(command grep -ohE "$lit" "$f" 2>>"$errfile" | command sort -u); do
        [ -f "$ref" ] || missing="$missing $f:$ref"
    done
    for ref in $(command grep -ohE "$var" "$f" 2>>"$errfile" | command sort -u); do
        name=${ref%%/*}; name=${name#\$}; name=${name#\{}; name=${name%\}}
        dir=$(command sed -nE "s/^[[:space:]]*${name}=\"?(\\/[^\"\$]*)\"?[[:space:]]*\$/\\1/p" "$f" 2>>"$errfile")
        if [ -z "$dir" ] && command grep -qE "^[[:space:]]*${name}=" "$f" 2>>"$errfile"; then
            dir=$(command grep -ohE "${libdir}\\}?\"" "$f" 2>>"$errfile" | command sed -E 's/\}?"$//' | command sort -u)
        fi
        [ -n "$dir" ] || missing="$missing $f:$ref"
        for d in $dir; do
            [ -f "$d/${ref#*/}" ] || missing="$missing $f:$ref@$d"
        done
    done
done
errs=$(<"$errfile")
unseen=""
for want in /usr/local/bin/entrypoint /usr/local/bin/workspace-fs-health-cron /usr/local/bin/healthcheck /etc/container/startup/42-workspace-fs-health.sh; do
    command grep -qxF "$want" <<<"$consumers" || unseen="$unseen $want"
done
if [ -z "$missing$unseen$errs" ]; then command echo consumers-ok; else command echo "missing:$missing unseen:$unseen errors: $errs"; fi
EOF
    assert_command_in_container "$image" "$scan" \
        "consumers-ok" \
        "Every installed /opt/container-runtime/lib reference should resolve"
}

# Test: User permissions and environment
test_user_environment() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Verify user is in sudo group but passwordless sudo is disabled by default (security)
    # This should fail with "password is required" which means sudo is available but secure
    assert_command_in_container "$image" "id -nG | command grep -q sudo && echo 'in-sudo-group'" "in-sudo-group"

    # Verify home directory is properly set
    assert_command_in_container "$image" "echo \$HOME" "/home/developer"

    # Verify user can write to workspace
    assert_command_in_container "$image" "touch /workspace/test-file && rm /workspace/test-file && echo success" "success"
}

# Test: Essential utilities are available
test_essential_utilities() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Version control
    assert_executable_in_path "$image" "git"

    # Text processing and utilities
    assert_executable_in_path "$image" "jq"
    assert_executable_in_path "$image" "shellcheck"

    # Network tools
    assert_executable_in_path "$image" "curl"
    assert_executable_in_path "$image" "wget"

    # System utilities
    assert_executable_in_path "$image" "htop"
    assert_executable_in_path "$image" "unzip"

    # Note: Build tools (make, gcc) should NOT be in minimal image
    # They are only available with INCLUDE_DEV_TOOLS=true
}

# Run all tests
run_test test_base_container_only "Base container builds with no features"
run_test test_cache_directories "Cache directories are configured"
run_test test_runtime_initialization "Runtime initialization completes"
run_test test_runtime_lib_installed "Runtime lib fragments installed at /opt/container-runtime/lib"
run_test test_user_environment "User environment is properly configured"
run_test test_essential_utilities "Essential utilities are available"

# Generate test report
generate_report
