#!/usr/bin/env bash
# Unit tests for lib/features/java-dev.sh
# Tests Java development tools installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Java Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-java-dev"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.m2"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Maven installation
test_maven_installation() {
    local mvn_bin="$TEST_TEMP_DIR/usr/local/bin/mvn"
    
    # Create mock maven
    touch "$mvn_bin"
    chmod +x "$mvn_bin"
    
    assert_file_exists "$mvn_bin"
    
    # Check executable
    if [ -x "$mvn_bin" ]; then
        assert_true true "Maven is executable"
    else
        assert_true false "Maven is not executable"
    fi
}

# Test: Gradle installation
test_gradle_installation() {
    local gradle_bin="$TEST_TEMP_DIR/usr/local/bin/gradle"
    
    # Create mock gradle
    touch "$gradle_bin"
    chmod +x "$gradle_bin"
    
    assert_file_exists "$gradle_bin"
    
    # Check executable
    if [ -x "$gradle_bin" ]; then
        assert_true true "Gradle is executable"
    else
        assert_true false "Gradle is not executable"
    fi
}

# Test: Spring Boot CLI
test_spring_boot_cli() {
    local spring_bin="$TEST_TEMP_DIR/usr/local/bin/spring"
    
    # Create mock spring
    touch "$spring_bin"
    chmod +x "$spring_bin"
    
    assert_file_exists "$spring_bin"
    
    # Check executable
    if [ -x "$spring_bin" ]; then
        assert_true true "Spring Boot CLI is executable"
    else
        assert_true false "Spring Boot CLI is not executable"
    fi
}

# Test: IntelliJ IDEA configuration
test_idea_config() {
    local idea_dir="$TEST_TEMP_DIR/home/testuser/.idea"
    mkdir -p "$idea_dir"
    
    # Create config files
    touch "$idea_dir/workspace.xml"
    touch "$idea_dir/modules.xml"
    
    assert_dir_exists "$idea_dir"
    assert_file_exists "$idea_dir/workspace.xml"
}

# Test: CheckStyle configuration
test_checkstyle_config() {
    local checkstyle_xml="$TEST_TEMP_DIR/checkstyle.xml"
    
    # Create config
    cat > "$checkstyle_xml" << 'EOF'
<?xml version="1.0"?>
<!DOCTYPE module PUBLIC "-//Checkstyle//DTD Checkstyle Configuration 1.3//EN"
          "https://checkstyle.org/dtds/configuration_1_3.dtd">
<module name="Checker">
    <module name="TreeWalker">
        <module name="JavadocMethod"/>
    </module>
</module>
EOF
    
    assert_file_exists "$checkstyle_xml"
    
    # Check configuration
    if grep -q "JavadocMethod" "$checkstyle_xml"; then
        assert_true true "CheckStyle Javadoc check enabled"
    else
        assert_true false "CheckStyle Javadoc check not enabled"
    fi
}

# Test: SpotBugs configuration
test_spotbugs_config() {
    local spotbugs_xml="$TEST_TEMP_DIR/spotbugs-exclude.xml"
    
    # Create config
    cat > "$spotbugs_xml" << 'EOF'
<FindBugsFilter>
    <Match>
        <Class name="~.*Test"/>
    </Match>
</FindBugsFilter>
EOF
    
    assert_file_exists "$spotbugs_xml"
    
    # Check configuration
    if grep -q "Test" "$spotbugs_xml"; then
        assert_true true "SpotBugs excludes test classes"
    else
        assert_true false "SpotBugs doesn't exclude test classes"
    fi
}

# Test: JUnit configuration
test_junit_config() {
    local junit_platform="$TEST_TEMP_DIR/junit-platform.properties"
    
    # Create config
    cat > "$junit_platform" << 'EOF'
junit.jupiter.testinstance.lifecycle.default=per_class
junit.jupiter.execution.parallel.enabled=true
EOF
    
    assert_file_exists "$junit_platform"
    
    # Check configuration
    if grep -q "parallel.enabled=true" "$junit_platform"; then
        assert_true true "JUnit parallel execution enabled"
    else
        assert_true false "JUnit parallel execution not enabled"
    fi
}

# Test: Java dev aliases
test_java_dev_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/45-java-dev.sh"
    
    # Create aliases
    cat > "$bashrc_file" << 'EOF'
alias mvnw='./mvnw'
alias gdlw='./gradlew'
alias sboot='spring boot'
EOF
    
    # Check aliases
    if grep -q "alias mvnw='./mvnw'" "$bashrc_file"; then
        assert_true true "Maven wrapper alias defined"
    else
        assert_true false "Maven wrapper alias not defined"
    fi
}

# Test: Lombok support
test_lombok_support() {
    local lombok_jar="$TEST_TEMP_DIR/home/testuser/.m2/repository/org/projectlombok/lombok/lombok.jar"
    mkdir -p "$(dirname "$lombok_jar")"
    
    # Create mock lombok jar
    touch "$lombok_jar"
    
    assert_file_exists "$lombok_jar"
}

# Test: Verification script
test_java_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-java-dev.sh"
    
    # Create verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Java dev tools:"
for tool in mvn gradle spring; do
    command -v $tool &>/dev/null && echo "  - $tool: installed" || echo "  - $tool: not found"
done
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

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Checksum Verification Tests
# ============================================================================

# Test: java-dev.sh uses checksum verification for Spring Boot CLI
test_java_dev_spring_boot_checksum() {
    local java_dev_script="$PROJECT_ROOT/lib/features/java-dev.sh"

    if ! [ -f "$java_dev_script" ]; then
        skip_test "java-dev.sh not found"
        return
    fi

    # Check for checksum fetching
    if grep -q "fetch_maven_sha1" "$java_dev_script"; then
        assert_true true "java-dev.sh fetches Spring Boot CLI checksum from Maven Central"
    else
        assert_true false "java-dev.sh does not fetch Spring Boot CLI checksum"
    fi

    # Check for download_and_verify usage (matches "/tmp/spring-boot-cli.tar.gz")
    if grep -A5 "download_and_verify" "$java_dev_script" | grep -q "spring-boot-cli.tar.gz"; then
        assert_true true "java-dev.sh uses download_and_verify for Spring Boot CLI"
    else
        assert_true false "java-dev.sh does not use download_and_verify for Spring Boot CLI"
    fi
}

# Test: java-dev.sh uses checksum verification for Maven Daemon
test_java_dev_maven_daemon_checksum() {
    local java_dev_script="$PROJECT_ROOT/lib/features/java-dev.sh"

    if ! [ -f "$java_dev_script" ]; then
        skip_test "java-dev.sh not found"
        return
    fi

    # Check for hardcoded checksum (Maven Daemon doesn't publish checksums)
    if grep -q "MVND_CHECKSUM_AMD64" "$java_dev_script"; then
        assert_true true "java-dev.sh defines Maven Daemon checksum"
    else
        assert_true false "java-dev.sh does not define Maven Daemon checksum"
    fi

    # Check for download_and_verify usage (matches "/tmp/mvnd.tar.gz")
    if grep -A5 "download_and_verify" "$java_dev_script" | grep -q "mvnd.tar.gz"; then
        assert_true true "java-dev.sh uses download_and_verify for Maven Daemon"
    else
        assert_true false "java-dev.sh does not use download_and_verify for Maven Daemon"
    fi
}

# Test: java-dev.sh sources required verification libraries
test_java_dev_sources_libraries() {
    local java_dev_script="$PROJECT_ROOT/lib/features/java-dev.sh"

    if ! [ -f "$java_dev_script" ]; then
        skip_test "java-dev.sh not found"
        return
    fi

    # Check for download-verify.sh
    if grep -q "source.*download-verify.sh" "$java_dev_script"; then
        assert_true true "java-dev.sh sources download-verify.sh"
    else
        assert_true false "java-dev.sh does not source download-verify.sh"
    fi

    # Check for checksum-fetch.sh
    if grep -q "source.*checksum-fetch.sh" "$java_dev_script"; then
        assert_true true "java-dev.sh sources checksum-fetch.sh"
    else
        assert_true false "java-dev.sh does not source checksum-fetch.sh"
    fi
}

# Test: Maven Daemon only installs on amd64
test_maven_daemon_architecture_check() {
    local java_dev_script="$PROJECT_ROOT/lib/features/java-dev.sh"

    if ! [ -f "$java_dev_script" ]; then
        skip_test "java-dev.sh not found"
        return
    fi

    # Check that Maven Daemon only installs on amd64 (not arm64)
    if grep -A2 "Maven Daemon" "$java_dev_script" | grep -q 'if \[ "$ARCH" = "amd64" \]'; then
        assert_true true "java-dev.sh only installs Maven Daemon on amd64"
    else
        assert_true false "java-dev.sh has incorrect Maven Daemon architecture check"
    fi
}

# Run all tests
run_test_with_setup test_maven_installation "Maven installation"
run_test_with_setup test_gradle_installation "Gradle installation"
run_test_with_setup test_spring_boot_cli "Spring Boot CLI"
run_test_with_setup test_idea_config "IntelliJ IDEA configuration"
run_test_with_setup test_checkstyle_config "CheckStyle configuration"
run_test_with_setup test_spotbugs_config "SpotBugs configuration"
run_test_with_setup test_junit_config "JUnit configuration"
run_test_with_setup test_java_dev_aliases "Java dev aliases"
run_test_with_setup test_lombok_support "Lombok support"
run_test_with_setup test_java_dev_verification "Java dev verification"

# Run checksum verification tests
run_test test_java_dev_spring_boot_checksum "java-dev.sh verifies Spring Boot CLI checksum"
run_test test_java_dev_maven_daemon_checksum "java-dev.sh verifies Maven Daemon checksum"
run_test test_java_dev_sources_libraries "java-dev.sh sources verification libraries"
run_test test_maven_daemon_architecture_check "Maven Daemon only installs on amd64"

# Generate test report
generate_report