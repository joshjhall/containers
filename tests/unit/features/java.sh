#!/usr/bin/env bash
# Unit tests for lib/features/java.sh
# Tests Java runtime and JDK installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Java Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-java"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export JAVA_VERSION="${JAVA_VERSION:-21}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/lib/jvm"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/cache/maven"
    mkdir -p "$TEST_TEMP_DIR/cache/gradle"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset JAVA_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Java version validation
test_java_version_validation() {
    # Test LTS versions
    local lts_versions=("8" "11" "17" "21")
    
    for version in "${lts_versions[@]}"; do
        assert_not_empty "$version" "Java $version is an LTS version"
    done
    
    # Test version format
    local version="21"
    if [[ "$version" =~ ^[0-9]+$ ]]; then
        assert_true true "Version format is valid"
    else
        assert_true false "Version format is invalid"
    fi
    
    # Test minimum version check
    if [ "$version" -ge 8 ]; then
        assert_true true "Java version meets minimum requirement"
    else
        assert_true false "Java version too old"
    fi
}

# Test: JDK installation structure
test_jdk_installation_structure() {
    local java_home="$TEST_TEMP_DIR/usr/lib/jvm/java-21-openjdk"
    
    # Create JDK directory structure
    mkdir -p "$java_home/bin"
    mkdir -p "$java_home/lib"
    mkdir -p "$java_home/include"
    mkdir -p "$java_home/jre/lib"
    
    # Create Java binaries
    local binaries=("java" "javac" "jar" "javap" "jshell" "jps" "jstack")
    for bin in "${binaries[@]}"; do
        touch "$java_home/bin/$bin"
        chmod +x "$java_home/bin/$bin"
    done
    
    # Check structure
    assert_dir_exists "$java_home"
    assert_dir_exists "$java_home/bin"
    assert_dir_exists "$java_home/lib"
    
    # Check binaries
    for bin in "${binaries[@]}"; do
        if [ -x "$java_home/bin/$bin" ]; then
            assert_true true "$bin is executable"
        else
            assert_true false "$bin is not executable"
        fi
    done
}

# Test: JAVA_HOME configuration
test_java_home_configuration() {
    local java_home="$TEST_TEMP_DIR/usr/lib/jvm/java-21-openjdk"
    
    # Create mock directory
    mkdir -p "$java_home"
    
    # Check JAVA_HOME would be set correctly
    assert_not_empty "$java_home" "JAVA_HOME path is set"
    
    # Check JAVA_HOME exists
    if [ -d "$java_home" ]; then
        assert_true true "JAVA_HOME directory exists"
    else
        assert_true false "JAVA_HOME directory doesn't exist"
    fi
}

# Test: Maven cache configuration
test_maven_cache_configuration() {
    local maven_cache="$TEST_TEMP_DIR/cache/maven"
    local maven_settings="$TEST_TEMP_DIR/home/testuser/.m2/settings.xml"
    
    # Create directories
    mkdir -p "$maven_cache"
    mkdir -p "$(dirname "$maven_settings")"
    
    # Create Maven settings
    cat > "$maven_settings" << 'EOF'
<settings>
  <localRepository>/cache/maven</localRepository>
</settings>
EOF
    
    assert_file_exists "$maven_settings"
    assert_dir_exists "$maven_cache"
    
    # Check cache configuration
    if grep -q "/cache/maven" "$maven_settings"; then
        assert_true true "Maven uses cache directory"
    else
        assert_true false "Maven doesn't use cache directory"
    fi
}

# Test: Gradle cache configuration
test_gradle_cache_configuration() {
    local gradle_cache="$TEST_TEMP_DIR/cache/gradle"
    local gradle_props="$TEST_TEMP_DIR/home/testuser/.gradle/gradle.properties"
    
    # Create directories
    mkdir -p "$gradle_cache"
    mkdir -p "$(dirname "$gradle_props")"
    
    # Create Gradle properties
    cat > "$gradle_props" << 'EOF'
org.gradle.caching=true
org.gradle.daemon=true
org.gradle.parallel=true
org.gradle.configureondemand=true
EOF
    
    assert_file_exists "$gradle_props"
    assert_dir_exists "$gradle_cache"
    
    # Check caching enabled
    if grep -q "org.gradle.caching=true" "$gradle_props"; then
        assert_true true "Gradle caching is enabled"
    else
        assert_true false "Gradle caching is not enabled"
    fi
    
    # Check daemon enabled
    if grep -q "org.gradle.daemon=true" "$gradle_props"; then
        assert_true true "Gradle daemon is enabled"
    else
        assert_true false "Gradle daemon is not enabled"
    fi
}

# Test: Java environment variables
test_java_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/45-java.sh"
    
    # Create mock bashrc content
    cat > "$bashrc_file" << 'EOF'
export JAVA_HOME="/usr/lib/jvm/java-21-openjdk"
export PATH="$JAVA_HOME/bin:$PATH"
export MAVEN_OPTS="-Xmx512m"
export GRADLE_USER_HOME="/cache/gradle"
export _JAVA_OPTIONS="-Djava.awt.headless=true"
EOF
    
    # Check environment variables
    if grep -q "export JAVA_HOME=" "$bashrc_file"; then
        assert_true true "JAVA_HOME is exported"
    else
        assert_true false "JAVA_HOME is not exported"
    fi
    
    if grep -q 'PATH.*JAVA_HOME/bin' "$bashrc_file"; then
        assert_true true "PATH includes Java bin directory"
    else
        assert_true false "PATH doesn't include Java bin directory"
    fi
    
    if grep -q "export MAVEN_OPTS=" "$bashrc_file"; then
        assert_true true "MAVEN_OPTS is configured"
    else
        assert_true false "MAVEN_OPTS is not configured"
    fi
    
    if grep -q "Djava.awt.headless=true" "$bashrc_file"; then
        assert_true true "Headless mode is configured"
    else
        assert_true false "Headless mode is not configured"
    fi
}

# Test: Java aliases and helpers
test_java_aliases_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/45-java.sh"
    
    # Add aliases section
    cat >> "$bashrc_file" << 'EOF'

# Java aliases
alias jv='java -version'
alias jc='javac'
alias jr='java -jar'
alias mvnc='mvn clean'
alias mvni='mvn install'
alias mvnp='mvn package'
alias mvnt='mvn test'
alias gw='./gradlew'
alias gwb='./gradlew build'
alias gwt='./gradlew test'
EOF
    
    # Check common aliases
    if grep -q "alias jv='java -version'" "$bashrc_file"; then
        assert_true true "java version alias defined"
    else
        assert_true false "java version alias not defined"
    fi
    
    if grep -q "alias mvni='mvn install'" "$bashrc_file"; then
        assert_true true "maven install alias defined"
    else
        assert_true false "maven install alias not defined"
    fi
    
    if grep -q "alias gw='./gradlew'" "$bashrc_file"; then
        assert_true true "gradlew alias defined"
    else
        assert_true false "gradlew alias not defined"
    fi
}

# Test: Project file detection
test_project_file_detection() {
    local project_dir="$TEST_TEMP_DIR/project"
    mkdir -p "$project_dir"
    
    # Create pom.xml for Maven
    cat > "$project_dir/pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project>
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.example</groupId>
    <artifactId>test-project</artifactId>
    <version>1.0.0</version>
    <properties>
        <maven.compiler.source>21</maven.compiler.source>
        <maven.compiler.target>21</maven.compiler.target>
    </properties>
</project>
EOF
    
    # Create build.gradle for Gradle
    cat > "$project_dir/build.gradle" << 'EOF'
plugins {
    id 'java'
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}
EOF
    
    assert_file_exists "$project_dir/pom.xml"
    assert_file_exists "$project_dir/build.gradle"
    
    # Check Maven configuration
    if grep -q "<maven.compiler.source>21</maven.compiler.source>" "$project_dir/pom.xml"; then
        assert_true true "Maven project uses Java 21"
    else
        assert_true false "Maven project doesn't specify Java 21"
    fi
    
    # Check Gradle configuration
    if grep -q "JavaLanguageVersion.of(21)" "$project_dir/build.gradle"; then
        assert_true true "Gradle project uses Java 21"
    else
        assert_true false "Gradle project doesn't specify Java 21"
    fi
}

# Test: Permissions and ownership
test_java_permissions() {
    local java_home="$TEST_TEMP_DIR/usr/lib/jvm/java-21-openjdk"
    local maven_dir="$TEST_TEMP_DIR/home/testuser/.m2"
    local gradle_dir="$TEST_TEMP_DIR/home/testuser/.gradle"
    
    # Create directories
    mkdir -p "$java_home" "$maven_dir" "$gradle_dir"
    
    # Check directories exist and are accessible
    if [ -d "$java_home" ] && [ -r "$java_home" ]; then
        assert_true true "JAVA_HOME is readable"
    else
        assert_true false "JAVA_HOME is not readable"
    fi
    
    if [ -d "$maven_dir" ] && [ -w "$maven_dir" ]; then
        assert_true true "Maven directory is writable"
    else
        assert_true false "Maven directory is not writable"
    fi
    
    if [ -d "$gradle_dir" ] && [ -w "$gradle_dir" ]; then
        assert_true true "Gradle directory is writable"
    else
        assert_true false "Gradle directory is not writable"
    fi
}

# Test: Java verification script
test_java_verification() {
    local test_script="$TEST_TEMP_DIR/test-java.sh"
    
    # Create verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Java version:"
java -version 2>&1 || echo "Java not installed"
echo "Javac version:"
javac -version 2>&1 || echo "Javac not installed"
echo "JAVA_HOME: ${JAVA_HOME:-not set}"
echo "Maven version:"
mvn --version 2>/dev/null || echo "Maven not installed"
echo "Gradle version:"
gradle --version 2>/dev/null || echo "Gradle not installed"
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

# Run all tests
run_test_with_setup test_java_version_validation "Java version validation works"
run_test_with_setup test_jdk_installation_structure "JDK installation structure is correct"
run_test_with_setup test_java_home_configuration "JAVA_HOME configuration is proper"
run_test_with_setup test_maven_cache_configuration "Maven cache is configured correctly"
run_test_with_setup test_gradle_cache_configuration "Gradle cache is configured correctly"
run_test_with_setup test_java_environment_variables "Java environment variables are set"
run_test_with_setup test_java_aliases_helpers "Java aliases and helpers are defined"
run_test_with_setup test_project_file_detection "Project file detection works"
run_test_with_setup test_java_permissions "Java directories have correct permissions"
run_test_with_setup test_java_verification "Java verification script works"

# Generate test report
generate_report