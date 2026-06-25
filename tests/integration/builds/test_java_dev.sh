#!/usr/bin/env bash
# @tier: merge,weekly
# Test java-dev container build
#
# This test verifies the Java development environment that includes:
# - JDK + Maven (implied by INCLUDE_JAVA, pulled in by INCLUDE_JAVA_DEV)
# - Spring Boot CLI (spring)
# - JBang Java scripting (jbang)
# - Maven Daemon (mvnd)
# - google-java-format formatter
#
# Coverage note: java-dev is skip-listed in the PR tier (test-pr.yml)
# because it is apt/download-bound and exceeds the 15min per-cell cap, so
# the merge tier owns its build coverage. See #536 / #531.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Java Development Container Build"

# Test: java-dev environment builds successfully
test_java_dev_build() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-java-dev-$$"
        # INCLUDE_JAVA_DEV implies INCLUDE_JAVA (JDK + Maven)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-java-dev \
            --build-arg INCLUDE_JAVA_DEV=true \
            -t "$image"
    fi

    # Verify the JDK and Maven that java-dev depends on are present
    assert_executable_in_path "$image" "java"
    assert_executable_in_path "$image" "mvn"
}

# Test: base Java toolchain works
test_java_toolchain() {
    local image="${IMAGE_TO_TEST:-test-java-dev-$$}"

    assert_command_in_container "$image" "java -version 2>&1" "version"
    assert_command_in_container "$image" "mvn --version" "Apache Maven"
}

# Test: java-dev binary tools install and run
#
# The four tools are installed by lib/features/java-dev.sh as symlinks on
# PATH; presence is the acceptance criterion (#536). For the three that
# expose a stable --version, we also assert it executes (exit 0) — mirroring
# the in-image test-java-dev helper, which runs --version for spring/jbang/
# mvnd but only checks presence for google-java-format.
test_java_dev_tools() {
    local image="${IMAGE_TO_TEST:-test-java-dev-$$}"

    # Spring Boot CLI
    assert_executable_in_path "$image" "spring"
    assert_command_in_container "$image" "spring --version"

    # JBang Java scripting tool
    assert_executable_in_path "$image" "jbang"
    assert_command_in_container "$image" "jbang --version"

    # Maven Daemon (mvnd) — installed on x86_64/arm64, which covers CI runners
    assert_executable_in_path "$image" "mvnd"
    assert_command_in_container "$image" "mvnd --version"

    # google-java-format formatter (wrapper invokes java -jar) — presence only,
    # matching the in-image helper (its --version output is not stable).
    assert_executable_in_path "$image" "google-java-format"
}

# Run all tests
run_test test_java_dev_build "Java dev environment builds successfully"
run_test test_java_toolchain "JDK and Maven work"
run_test test_java_dev_tools "Java dev binary tools install and run"

# Generate test report
generate_report
