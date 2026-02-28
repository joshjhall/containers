#!/bin/bash
# shellcheck disable=SC2154  # Variables in helper functions assigned from parameters
# Java Development Tools - Advanced development utilities for Java
#
# Description:
#   Installs comprehensive Java development tools for testing, code quality,
#   debugging, and productivity. These complement the base Java installation
#   with modern development utilities.
#
# Tools Installed:
#   - Testing: JUnit Platform Console, TestNG
#   - Code Quality: SpotBugs, PMD, Checkstyle, Error Prone
#   - Build Enhancement: Maven Wrapper, Gradle Wrapper installers
#   - Spring Boot CLI: Rapid Spring application development
#   - JReleaser: Modern release automation
#   - JBang: Java scripting and single-file execution
#   - SDKMAN!: Java SDK version management
#   - Lombok: Boilerplate code reduction
#   - JMH: Java Microbenchmark Harness
#
# Requirements:
#   - Java must be installed (via INCLUDE_JAVA=true)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Source checksum fetching utilities
source /tmp/build-scripts/base/checksum-fetch.sh

# Source 4-tier checksum verification system
source /tmp/build-scripts/base/checksum-verification.sh

# Source jdtls installation utilities
source /tmp/build-scripts/features/lib/install-jdtls.sh

# Start logging
log_feature_start "Java Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check if Java is available
if [ ! -f "/usr/local/bin/java" ]; then
    log_error "Java not found at /usr/local/bin/java"
    log_error "The INCLUDE_JAVA feature must be enabled before java-dev tools can be installed"
    log_feature_end
    exit 1
fi

# Check if Maven is available
if [ ! -f "/usr/local/bin/mvn" ]; then
    log_error "Maven not found at /usr/local/bin/mvn"
    log_error "The INCLUDE_JAVA feature must be enabled first"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Java dev tools..."

log_message "Updating package lists and installing dependencies..."

# Update package lists with retry logic
apt_update

# Install system dependencies with retry logic
apt_install \
    unzip \
    zip \
    jq

# ============================================================================
# Development Tools Installation
# ============================================================================
log_message "Installing Java development tools..."

# Set up tool installation directory
TOOLS_DIR="/opt/java-tools"
log_command "Creating tools directory" \
    mkdir -p "${TOOLS_DIR}/bin"

# ============================================================================
# Spring Boot CLI
# ============================================================================
log_message "Installing Spring Boot CLI..."

SPRING_VERSION="${SPRING_VERSION:-4.0.3}"
export SPRING_VERSION  # Export for use in shell functions

# Build Maven Central URL
SPRING_BASE_URL="https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-cli/${SPRING_VERSION}/spring-boot-cli-${SPRING_VERSION}-bin.tar.gz"

# Register Tier 3 fetcher for Spring Boot CLI (Maven Central SHA256)
_fetch_spring_cli_checksum() {
    local _ver="$1"
    local _url="https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-cli/${_ver}/spring-boot-cli-${_ver}-bin.tar.gz"
    fetch_maven_sha256 "$_url" 2>/dev/null
}
register_tool_checksum_fetcher "spring-boot-cli" "_fetch_spring_cli_checksum"

# Download Spring Boot CLI
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading Spring Boot CLI ${SPRING_VERSION}..."
if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "spring-boot-cli.tar.gz" "${SPRING_BASE_URL}"; then
    log_error "Failed to download Spring Boot CLI ${SPRING_VERSION}"
    log_feature_end
    exit 1
fi

# Run 4-tier verification
verify_rc=0
verify_download "tool" "spring-boot-cli" "$SPRING_VERSION" "spring-boot-cli.tar.gz" "$(dpkg --print-architecture)" || verify_rc=$?
if [ "$verify_rc" -eq 1 ]; then
    log_error "Verification failed for Spring Boot CLI ${SPRING_VERSION}"
    log_feature_end
    exit 1
fi

log_command "Extracting Spring Boot CLI" \
    tar -xzf spring-boot-cli.tar.gz -C "${TOOLS_DIR}"

create_symlink "${TOOLS_DIR}/spring-${SPRING_VERSION}/bin/spring" "/usr/local/bin/spring" "Spring Boot CLI"

cd /

# ============================================================================
# JBang - Java Scripting
# ============================================================================
log_message "Installing JBang..."

# Download and extract JBang directly (more reliable than installer script)
JBANG_VERSION="${JBANG_VERSION:-0.137.0}"
JBANG_TAR="jbang-${JBANG_VERSION}.tar"
JBANG_URL="https://github.com/jbangdev/jbang/releases/download/v${JBANG_VERSION}/${JBANG_TAR}"

# Register Tier 3 fetcher for JBang
_fetch_jbang_checksum() {
    local _ver="$1"
    local _tar="jbang-${_ver}.tar"
    local _url="https://github.com/jbangdev/jbang/releases/download/v${_ver}/checksums_sha256.txt"
    fetch_github_checksums_txt "$_url" "$_tar" 2>/dev/null
}
register_tool_checksum_fetcher "jbang" "_fetch_jbang_checksum"

# Download JBang tarball
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading JBang..."
if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "jbang.tar" "$JBANG_URL"; then
    log_error "Failed to download JBang ${JBANG_VERSION}"
    log_feature_end
    exit 1
fi

# Run 4-tier verification
verify_rc=0
verify_download "tool" "jbang" "$JBANG_VERSION" "jbang.tar" "$(dpkg --print-architecture)" || verify_rc=$?
if [ "$verify_rc" -eq 1 ]; then
    log_error "Verification failed for JBang ${JBANG_VERSION}"
    log_feature_end
    exit 1
fi

log_message "✓ JBang v${JBANG_VERSION} verified successfully"

# Extract JBang
log_command "Extracting JBang" \
    tar -xf jbang.tar -C "${TOOLS_DIR}"

# Create symlink directly to the jbang script
create_symlink "${TOOLS_DIR}/jbang-${JBANG_VERSION}/bin/jbang" "/usr/local/bin/jbang" "JBang Java scripting tool"

cd /

# ============================================================================
# Maven Daemon - Faster Maven builds
# ============================================================================
# Note: Maven Daemon 1.0.3 only publishes amd64 builds (no arm64)
# Note: Maven Daemon does not publish checksums, using calculated SHA256
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    log_message "Installing Maven Daemon for ${ARCH}..."

    MVND_VERSION="1.0.3"
    MVND_URL="https://github.com/apache/maven-mvnd/releases/download/${MVND_VERSION}/maven-mvnd-${MVND_VERSION}-linux-${ARCH}.tar.gz"

    # Maven Daemon does not publish checksums — will be verified via Tier 2 (pinned) or Tier 4 (TOFU)
    # No fetcher registered — falls through to TOFU with unified logging

    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading Maven Daemon ${MVND_VERSION}..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "mvnd.tar.gz" "${MVND_URL}"; then
        log_error "Failed to download Maven Daemon ${MVND_VERSION}"
        log_feature_end
        exit 1
    fi

    # Run 4-tier verification
    verify_rc=0
    verify_download "tool" "mvnd" "$MVND_VERSION" "mvnd.tar.gz" "$ARCH" || verify_rc=$?
    if [ "$verify_rc" -eq 1 ]; then
        log_error "Verification failed for Maven Daemon ${MVND_VERSION}"
        log_feature_end
        exit 1
    fi

    log_command "Extracting Maven Daemon" \
        tar -xzf mvnd.tar.gz -C "${TOOLS_DIR}"

    create_symlink "${TOOLS_DIR}/maven-mvnd-${MVND_VERSION}-linux-${ARCH}/bin/mvnd" "/usr/local/bin/mvnd" "Maven Daemon"
    create_symlink "${TOOLS_DIR}/maven-mvnd-${MVND_VERSION}-linux-${ARCH}/bin/mvnd" "/usr/local/bin/mvndaemon" "Maven Daemon (alias)"

    cd /
else
    log_message "Skipping Maven Daemon installation - only available for amd64 architecture (detected: ${ARCH})"
fi

# ============================================================================
# Code Quality Tools (Optional)
# ============================================================================
log_message "Installing code quality tools (best effort)..."

# Create a directory for standalone JARs
JARS_DIR="${TOOLS_DIR}/jars"
log_command "Creating JARs directory" \
    mkdir -p "${JARS_DIR}"

# Note: We're skipping the complex code quality tools (SpotBugs, PMD, Checkstyle)
# as they have frequent download issues and can be installed via Maven plugins instead.
# Users can install them with:
#   mvn com.github.spotbugs:spotbugs-maven-plugin:check
#   mvn pmd:check
#   mvn checkstyle:check

# ============================================================================
# Google Java Format - Essential formatter
# ============================================================================
log_message "Installing Google Java Format..."

GJF_VERSION="${GJF_VERSION:-1.34.1}"

# JMH version for benchmarking
JMH_VERSION="1.37"
export JMH_VERSION  # Export for use in shell functions
GJF_URL="https://github.com/google/google-java-format/releases/download/v${GJF_VERSION}/google-java-format-${GJF_VERSION}-all-deps.jar"
# Google Java Format does not publish checksums — will be TOFU with unified logging
if command wget -q --spider "${GJF_URL}" 2>/dev/null; then
    log_message "Downloading Google Java Format ${GJF_VERSION}..."
    if command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "${JARS_DIR}/google-java-format.jar" "${GJF_URL}"; then
        # Run 4-tier verification (no fetcher registered — will be TOFU)
        verify_rc=0
        verify_download "tool" "google-java-format" "$GJF_VERSION" "${JARS_DIR}/google-java-format.jar" "$(dpkg --print-architecture)" || verify_rc=$?
        if [ "$verify_rc" -eq 1 ]; then
            log_warning "Verification failed for Google Java Format, removing..."
            command rm -f "${JARS_DIR}/google-java-format.jar"
        fi
    fi

    # Create wrapper script
    command cat > /usr/local/bin/google-java-format << 'EOF'
#!/bin/bash
java -jar /opt/java-tools/jars/google-java-format.jar "$@"
EOF
    log_command "Setting Google Java Format script permissions" \
        chmod +x /usr/local/bin/google-java-format
else
    log_warning "Google Java Format not available, skipping..."
fi

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Java development helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add java-dev aliases and helpers (content in lib/bashrc/java-dev.sh)
write_bashrc_content /etc/bashrc.d/55-java-dev.sh "Java development tools" \
    < /tmp/build-scripts/features/lib/bashrc/java-dev.sh

log_command "Setting Java dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/55-java-dev.sh

# ============================================================================
# Create Development Templates
# ============================================================================
log_message "Creating Java development templates..."

# Create templates directory
TEMPLATES_DIR="/etc/java-dev-templates"
log_command "Creating templates directory" \
    mkdir -p "${TEMPLATES_DIR}"

# Template loader function for build-time config generation
load_java_config_template() {
    local template_path="$1"
    local template_file="/tmp/build-scripts/features/templates/java/${template_path}"

    if [ ! -f "$template_file" ]; then
        log_error "Template not found: $template_file"
        return 1
    fi

    command cat "$template_file"
}

# Checkstyle configuration from template
log_message "Creating checkstyle.xml from template"
load_java_config_template "config/checkstyle.xml.tmpl" > "${TEMPLATES_DIR}/checkstyle.xml"

# PMD ruleset from template
log_message "Creating pmd-ruleset.xml from template"
load_java_config_template "config/pmd-ruleset.xml.tmpl" > "${TEMPLATES_DIR}/pmd-ruleset.xml"

# SpotBugs exclude filter from template
log_message "Creating spotbugs-exclude.xml from template"
load_java_config_template "config/spotbugs-exclude.xml.tmpl" > "${TEMPLATES_DIR}/spotbugs-exclude.xml"


# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating java-dev startup script..."

command cat > /etc/container/first-startup/35-java-dev-setup.sh << 'EOF'
#!/bin/bash
# Java development tools configuration
if command -v java &> /dev/null; then
    echo "=== Java Development Tools ==="

    # List available dev tools
    echo "Development tools available:"
    echo "  Spring Boot CLI: spring"
    echo "  JBang: jbang"
    echo "  Maven Daemon: mvnd"
    echo "  Code Quality: spotbugs, pmd, checkstyle"
    echo "  Formatting: google-java-format"
    echo "  Release: jreleaser"
    echo ""

    # Check for Java project
    if [ -f ${WORKING_DIR}/pom.xml ] || [ -f ${WORKING_DIR}/build.gradle* ]; then
        # Copy templates if they don't exist
        if [ ! -f ${WORKING_DIR}/checkstyle.xml ] && [ -f /etc/java-dev-templates/checkstyle.xml ]; then
            command cp /etc/java-dev-templates/checkstyle.xml ${WORKING_DIR}/
            echo "Created checkstyle.xml configuration"
        fi

        if [ ! -f ${WORKING_DIR}/pmd-ruleset.xml ] && [ -f /etc/java-dev-templates/pmd-ruleset.xml ]; then
            command cp /etc/java-dev-templates/pmd-ruleset.xml ${WORKING_DIR}/
            echo "Created pmd-ruleset.xml configuration"
        fi

        if [ ! -f ${WORKING_DIR}/spotbugs-exclude.xml ] && [ -f /etc/java-dev-templates/spotbugs-exclude.xml ]; then
            command cp /etc/java-dev-templates/spotbugs-exclude.xml ${WORKING_DIR}/
            echo "Created spotbugs-exclude.xml filter"
        fi

        echo ""
        echo "Quick commands:"
        echo "  java-quality-check   - Run all code quality tools"
        echo "  java-format-all      - Format all Java files"
        echo "  mvn-wrapper          - Add Maven wrapper"
        echo "  gradle-wrapper       - Add Gradle wrapper"
    fi
fi
EOF

log_command "Setting Java dev startup script permissions" \
    chmod +x /etc/container/first-startup/35-java-dev-setup.sh

# ============================================================================
# Eclipse JDT Language Server (jdtls)
# ============================================================================
log_message "Installing Eclipse JDT Language Server..."

# Install jdtls for IDE support (VS Code, Neovim, Claude Code)
install_jdtls
configure_jdtls_env

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating java-dev verification script..."

command cat > /usr/local/bin/test-java-dev << 'EOF'
#!/bin/bash
echo "=== Java Development Tools Status ==="

# Check main tools
echo ""
echo "Main development tools:"
for tool in spring jbang mvnd jreleaser; do
    if command -v $tool &> /dev/null; then
        case $tool in
            spring)
                version=$(spring --version 2>&1)
                ;;
            jbang)
                version=$(jbang --version 2>&1)
                ;;
            mvnd)
                version=$(mvnd --version 2>&1 | head -1)
                ;;
            jreleaser)
                version=$(jreleaser --version 2>&1)
                ;;
        esac
        echo "✓ $tool: $version"
    else
        echo "✗ $tool is not found"
    fi
done

# Check code quality tools
echo ""
echo "Code quality tools:"
for tool in spotbugs pmd cpd checkstyle google-java-format; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check IDE/Language Server
echo ""
echo "IDE/Language Server:"
if [ -d "/opt/jdtls" ]; then
    echo "✓ jdtls (Eclipse JDT Language Server) is installed"
else
    echo "✗ jdtls is not found"
fi

echo ""
echo "Run 'java-dev-help' to see available commands"
EOF

log_command "Setting test-java-dev script permissions" \
    chmod +x /usr/local/bin/test-java-dev

# Create help command
command cat > /usr/local/bin/java-dev-help << 'EOF'
#!/bin/bash
echo "=== Java Development Commands ==="
echo ""
echo "Project initialization:"
echo "  spring-init-web <name>    - Create Spring Boot web app"
echo "  spring-init-api <name>    - Create Spring Boot REST API"
echo "  jbang-init <script>       - Create JBang script"
echo "  mvn-create <group> <id>   - Create Maven project"
echo ""
echo "Code quality:"
echo "  java-quality-check        - Run all quality tools"
echo "  java-format-all           - Format all Java files"
echo "  pmd-java                  - Run PMD analysis"
echo "  cpd-java                  - Detect copy-paste"
echo ""
echo "Build tools:"
echo "  mvnd                      - Fast Maven builds"
echo "  mvn-wrapper               - Add Maven wrapper"
echo "  gradle-wrapper            - Add Gradle wrapper"
echo ""
echo "Utilities:"
echo "  java-benchmark <class>    - Create/run JMH benchmark"
echo "  jbang <script>            - Run Java scripts"
echo "  spring jar                - Create executable JAR"
EOF

log_command "Setting java-dev-help script permissions" \
    chmod +x /usr/local/bin/java-dev-help

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying key Java development tools..."

log_command "Checking Spring Boot CLI" \
    /usr/local/bin/spring --version || log_warning "Spring Boot CLI not installed"

log_command "Checking JBang" \
    /usr/local/bin/jbang --version || log_warning "JBang not installed"

log_command "Checking Maven Daemon" \
    /usr/local/bin/mvnd --version || log_warning "Maven Daemon not installed"

log_command "Checking SpotBugs" \
    /usr/local/bin/spotbugs -version || log_warning "SpotBugs not installed"

# Log feature summary
# Export directory paths for feature summary
export TOOLS_DIR="/opt/java-tools"
export JARS_DIR="${TOOLS_DIR}/jars"
export TEMPLATES_DIR="/etc/java-dev-templates"

log_feature_summary \
    --feature "Java Development Tools" \
    --tools "spring,jbang,mvnd,google-java-format,jreleaser" \
    --paths "${TOOLS_DIR},${JARS_DIR},${TEMPLATES_DIR}" \
    --env "SPRING_VERSION,JMH_VERSION" \
    --commands "spring,jbang,mvnd,google-java-format,spring-init-web,spring-init-api,jbang-init,java-format-all,java-quality-check" \
    --next-steps "Run 'test-java-dev' to check installed tools. Run 'java-dev-help' for available commands. Use spring-init-web/api to create projects."

# End logging
log_feature_end

echo ""
echo "Run 'test-java-dev' to check installed tools"
echo "Run 'java-dev-help' to see available commands"
echo "Run 'check-build-logs.sh java-development-tools' to review installation logs"
