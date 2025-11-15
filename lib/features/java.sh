#!/bin/bash
# Java Development Kit - OpenJDK with Maven and Gradle
#
# Description:
#   Installs Eclipse Temurin JDK and essential Java build tools for application development.
#   Uses consistent Adoptium distribution for all Java versions with proper toolchain.
#
# Features:
#   - OpenJDK: Open-source Java Development Kit
#   - Maven: Dependency management and build automation
#   - Gradle: Modern build tool with Groovy/Kotlin DSL
#   - Automatic JAVA_HOME configuration
#   - Multiple LTS version support
#   - Headless installation for container efficiency
#   - Cache optimization for Maven and Gradle
#
# Tools Installed:
#   - temurin-${JAVA_VERSION}-jdk: Eclipse Temurin JDK (all versions)
#   - maven: Apache Maven build tool
#   - gradle: Gradle build automation
#
# Environment Variables:
#   - JAVA_VERSION: Major version to install (default: 21 LTS)
#     Supported versions (all from Eclipse Temurin):
#     - 11: LTS (Long Term Support)
#     - 17: LTS (Long Term Support)
#     - 21: LTS (Long Term Support) - Latest LTS
#   - JAVA_HOME: JDK installation directory
#   - M2_HOME: Maven home directory
#
# Common Commands:
#   - java -version: Show Java version
#   - javac: Java compiler
#   - mvn clean install: Build with Maven
#   - gradle build: Build with Gradle
#
# Note:
#   Headless JDK is installed to minimize container size. For GUI applications,
#   install the full JDK package instead.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source version resolution for partial version support
source /tmp/build-scripts/base/version-resolution.sh
source /tmp/build-scripts/base/cache-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
# Java version to install (can be overridden)
JAVA_VERSION="${JAVA_VERSION:-21}"

# Validate Java version format to prevent shell injection
validate_java_version "$JAVA_VERSION" || {
    log_error "Build failed due to invalid JAVA_VERSION"
    exit 1
}

# Resolve partial versions to full versions for informational purposes
# Note: apt will automatically install the latest patch version for the major version
# This resolution is primarily for logging and transparency
if [[ "$JAVA_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ORIGINAL_VERSION="$JAVA_VERSION"
    RESOLVED_VERSION=$(resolve_java_version "$JAVA_VERSION" 2>/dev/null || echo "$JAVA_VERSION")

    if [ "$ORIGINAL_VERSION" != "$RESOLVED_VERSION" ]; then
        log_message "📍 Version Resolution: $ORIGINAL_VERSION → $RESOLVED_VERSION"
        log_message "   Note: apt will install latest patch for Java $ORIGINAL_VERSION"
        log_message "   Resolved version ($RESOLVED_VERSION) shown for reference"
    fi
fi

# Extract major version for package name (apt uses major version)
JAVA_MAJOR=$(echo "$JAVA_VERSION" | cut -d. -f1)

# Note: Java is installed via Eclipse Temurin apt packages
# Verification is handled by:
#   - Debian package system (dpkg verification)
#   - Adoptium repository GPG signatures
#   - No manual checksum verification needed

# Start logging
log_feature_start "Java" "${JAVA_VERSION}"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Java..."

log_message "Installing repository dependencies..."

# Update package lists with retry logic
apt_update

# Install repository dependencies with retry logic
apt_install \
    wget \
    apt-transport-https \
    gpg \
    ca-certificates

# ============================================================================
# Add Adoptium Repository
# ============================================================================
log_message "Adding Eclipse Temurin repository..."

log_command "Adding Adoptium GPG key" \
    bash -c "wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg"

log_command "Adding Adoptium repository" \
    bash -c 'echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(awk -F= '\''/^VERSION_CODENAME/{print$2}'\'' /etc/os-release) main" > /etc/apt/sources.list.d/adoptium.list'

# Update package lists with Adoptium repository
apt_update

# ============================================================================
# Java Installation
# ============================================================================
log_message "Installing Java ${JAVA_VERSION} and build tools..."

# Install Temurin JDK
log_message "Installing Eclipse Temurin JDK ${JAVA_VERSION}..."
apt_install "temurin-${JAVA_MAJOR}-jdk"

# Create consistent symlink for all versions
TEMURIN_PATH="/usr/lib/jvm/temurin-${JAVA_MAJOR}-jdk-$(dpkg --print-architecture)"
log_command "Creating Java version symlink" \
    ln -sf "${TEMURIN_PATH}" "/usr/lib/jvm/java-${JAVA_MAJOR}-openjdk-$(dpkg --print-architecture)"

# Install build tools
log_message "Installing build tools..."
apt_install maven gradle

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring Java cache directories..."

# ALWAYS use /cache paths for consistency with other languages
MAVEN_CACHE_DIR="/cache/maven"
GRADLE_HOME_DIR="/cache/gradle"

log_message "Java cache paths:"
log_message "  Maven repository: ${MAVEN_CACHE_DIR}"
log_message "  Gradle home: ${GRADLE_HOME_DIR}"

# Create cache directories with correct ownership using shared utility
create_cache_directories "${MAVEN_CACHE_DIR}" "${GRADLE_HOME_DIR}"

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Java environment..."

# Set JAVA_HOME and create default symlink
JAVA_HOME_PATH="/usr/lib/jvm/java-${JAVA_MAJOR}-openjdk-$(dpkg --print-architecture)"
log_command "Creating default Java symlink" \
    ln -sf "${JAVA_HOME_PATH}" /usr/lib/jvm/default-java

# ============================================================================
# Create symlinks for Java binaries
# ============================================================================
log_message "Creating Java symlinks..."

# Java installs to /usr/lib/jvm/*/bin, but update-alternatives usually handles this
# We'll ensure key commands are available in /usr/local/bin for consistency
JAVA_BIN_DIR="${JAVA_HOME_PATH}/bin"

for cmd in java javac jar javadoc javap; do
    if [ -f "${JAVA_BIN_DIR}/${cmd}" ]; then
        create_symlink "${JAVA_BIN_DIR}/${cmd}" "/usr/local/bin/${cmd}" "${cmd} Java tool"
    fi
done

# Maven and Gradle are typically installed to /usr/bin
for cmd in mvn gradle; do
    if [ -f "/usr/bin/${cmd}" ]; then
        create_symlink "/usr/bin/${cmd}" "/usr/local/bin/${cmd}" "${cmd} build tool"
    fi
done

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide Java environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Java configuration
write_bashrc_content /etc/bashrc.d/50-java.sh "Java environment configuration" << 'JAVA_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Java environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Java installation
export JAVA_HOME=/usr/lib/jvm/default-java
export PATH="$JAVA_HOME/bin:$PATH"

# Maven configuration
export M2_HOME=/usr/share/maven
export MAVEN_HOME=$M2_HOME
export PATH="$M2_HOME/bin:$PATH"
export MAVEN_OPTS="-Xmx1024m -XX:MaxMetaspaceSize=512m"

# Maven cache directory
export MAVEN_USER_HOME="/cache/maven"
export M2_REPO="${MAVEN_USER_HOME}/repository"

# Gradle configuration
export GRADLE_HOME=/usr/share/gradle
export PATH="$GRADLE_HOME/bin:$PATH"
export GRADLE_USER_HOME="/cache/gradle"
export GRADLE_OPTS="-Xmx1024m -XX:MaxMetaspaceSize=512m"

JAVA_BASHRC_EOF

log_command "Setting Java bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-java.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Java aliases and helpers..."

write_bashrc_content /etc/bashrc.d/50-java.sh "Java aliases and helpers" << 'JAVA_BASHRC_EOF'

# ----------------------------------------------------------------------------
# Java Aliases - Common development commands
# ----------------------------------------------------------------------------
# Maven aliases
alias mvnc='mvn clean'
alias mvnci='mvn clean install'
alias mvncp='mvn clean package'
alias mvncist='mvn clean install -DskipTests'
alias mvnt='mvn test'
alias mvnts='mvn test -Dtest='
alias mvndep='mvn dependency:tree'
alias mvndeps='mvn dependency:sources'
alias mvneff='mvn help:effective-pom'

# Gradle aliases
alias gw='./gradlew'
alias gwb='./gradlew build'
alias gwc='./gradlew clean'
alias gwcb='./gradlew clean build'
alias gwt='./gradlew test'
alias gwts='./gradlew test --tests'
alias gwdep='./gradlew dependencies'
alias gwtasks='./gradlew tasks'

# ----------------------------------------------------------------------------
# java-version - Show detailed Java version information
# ----------------------------------------------------------------------------
java-version() {
    echo "=== Java Environment ==="
    echo "Java Version:"
    java -version 2>&1 | head -n 3
    echo ""
    echo "JAVA_HOME: $JAVA_HOME"
    echo ""
    echo "Build Tools:"
    mvn --version 2>/dev/null | head -n 1 || echo "Maven not found"
    gradle --version 2>/dev/null | grep "Gradle" || echo "Gradle not found"
    echo ""
    echo "Cache Directories:"
    echo "  Maven: ${MAVEN_USER_HOME:-/cache/maven}"
    echo "  Gradle: ${GRADLE_USER_HOME:-/cache/gradle}"
}

# ----------------------------------------------------------------------------
# mvn-create - Create a new Maven project from archetype
#
# Arguments:
#   $1 - Group ID (required)
#   $2 - Artifact ID (required)
#   $3 - Archetype (optional, default: quickstart)
#
# Example:
#   mvn-create com.example my-app
#   mvn-create com.example my-webapp webapp
# ----------------------------------------------------------------------------
mvn-create() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: mvn-create <groupId> <artifactId> [archetype]"
        echo ""
        echo "Archetypes:"
        echo "  quickstart - Simple Java application (default)"
        echo "  webapp     - Web application"
        echo "  spring     - Spring Boot application"
        return 1
    fi

    local groupId="$1"
    local artifactId="$2"
    local archetype="${3:-quickstart}"

    case "$archetype" in
        webapp)
            mvn archetype:generate \
                -DgroupId="$groupId" \
                -DartifactId="$artifactId" \
                -DarchetypeArtifactId=maven-archetype-webapp \
                -DarchetypeVersion=1.4 \
                -DinteractiveMode=false
            ;;
        spring)
            mvn archetype:generate \
                -DgroupId="$groupId" \
                -DartifactId="$artifactId" \
                -DarchetypeGroupId=org.springframework.boot \
                -DarchetypeArtifactId=spring-boot-maven-archetype \
                -DinteractiveMode=false
            ;;
        *)
            mvn archetype:generate \
                -DgroupId="$groupId" \
                -DartifactId="$artifactId" \
                -DarchetypeArtifactId=maven-archetype-quickstart \
                -DarchetypeVersion=1.4 \
                -DinteractiveMode=false
            ;;
    esac
}

# ----------------------------------------------------------------------------
# gradle-init - Initialize a new Gradle project
#
# Arguments:
#   $1 - Project type (default: java-application)
#   $2 - DSL type (default: groovy, can be kotlin)
#
# Example:
#   gradle-init
#   gradle-init java-library
#   gradle-init java-application kotlin
# ----------------------------------------------------------------------------
gradle-init() {
    local type="${1:-java-application}"
    local dsl="${2:-groovy}"

    echo "Creating Gradle project (type: $type, DSL: $dsl)..."
    gradle init --type "$type" --dsl "$dsl"
}

# ----------------------------------------------------------------------------
# java-clean-cache - Clean Maven and Gradle caches
# ----------------------------------------------------------------------------
java-clean-cache() {
    echo "=== Cleaning Java build caches ==="

    if [ -d "${MAVEN_USER_HOME:-/cache/maven}/repository" ]; then
        echo "Cleaning Maven cache..."
        rm -rf "${MAVEN_USER_HOME:-/cache/maven}/repository"/*
    fi

    if [ -d "${GRADLE_USER_HOME:-/cache/gradle}/caches" ]; then
        echo "Cleaning Gradle cache..."
        rm -rf "${GRADLE_USER_HOME:-/cache/gradle}/caches"/*
    fi

    echo "Cache cleanup complete"
}

# ----------------------------------------------------------------------------
# mvn-deps-update - Check and update Maven dependencies
# ----------------------------------------------------------------------------
mvn-deps-update() {
    echo "=== Checking for Maven dependency updates ==="
    mvn versions:display-dependency-updates
    echo ""
    echo "To update dependencies, use:"
    echo "  mvn versions:use-latest-releases"
    echo "  mvn versions:use-latest-snapshots"
}

# ----------------------------------------------------------------------------
# gradle-deps-update - Check Gradle dependencies
# ----------------------------------------------------------------------------
gradle-deps-update() {
    echo "=== Checking for Gradle dependency updates ==="
    if [ -x "./gradlew" ]; then
        ./gradlew dependencyUpdates
    else
        gradle dependencyUpdates
    fi
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
JAVA_BASHRC_EOF

# ============================================================================
# Maven Settings Configuration
# ============================================================================
log_message "Creating Maven settings template..."

# Create Maven settings directory
log_command "Creating Maven config directory" \
    mkdir -p /etc/maven

# Create a template settings.xml that uses cache directory
cat > /etc/maven/settings-template.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0
                              http://maven.apache.org/xsd/settings-1.2.0.xsd">

    <!-- Local Repository Path -->
    <localRepository>/cache/maven/repository</localRepository>

    <!-- Mirrors for faster downloads -->
    <mirrors>
        <!-- Example: Use a closer mirror for Maven Central
        <mirror>
            <id>central-mirror</id>
            <mirrorOf>central</mirrorOf>
            <url>https://repo1.maven.org/maven2</url>
        </mirror>
        -->
    </mirrors>

    <!-- Profiles -->
    <profiles>
        <profile>
            <id>default</id>
            <activation>
                <activeByDefault>true</activeByDefault>
            </activation>
            <properties>
                <maven.compiler.source>${JAVA_MAJOR}</maven.compiler.source>
                <maven.compiler.target>${JAVA_MAJOR}</maven.compiler.target>
            </properties>
        </profile>
    </profiles>
</settings>
EOF

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Java startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/30-java-setup.sh << 'EOF'
#!/bin/bash
# Java development environment setup

# Set up Maven settings if not exists
if [ ! -f "$HOME/.m2/settings.xml" ] && [ -f "/etc/maven/settings-template.xml" ]; then
    mkdir -p "$HOME/.m2"
    cp /etc/maven/settings-template.xml "$HOME/.m2/settings.xml"
    echo "Created Maven settings.xml from template"
fi

# Check for Java projects
if [ -f ${WORKING_DIR}/pom.xml ]; then
    echo "=== Maven Project Detected ==="
    echo "Maven project found. Common commands:"
    echo "  mvn clean install    - Build and install"
    echo "  mvn test            - Run tests"
    echo "  mvn package         - Create JAR/WAR"
    echo "  mvndep              - Show dependency tree"

    if [ -f ${WORKING_DIR}/.mvn/settings.xml ]; then
        echo "Custom Maven settings detected in .mvn/"
    fi

    # Check for Spring Boot
    if grep -q "spring-boot" ${WORKING_DIR}/pom.xml 2>/dev/null; then
        echo ""
        echo "Spring Boot application detected!"
        echo "  mvn spring-boot:run  - Start the application"
    fi
elif [ -f ${WORKING_DIR}/build.gradle ] || [ -f ${WORKING_DIR}/build.gradle.kts ]; then
    echo "=== Gradle Project Detected ==="
    echo "Gradle project found. Common commands:"
    echo "  gradle build        - Build project"
    echo "  gradle test         - Run tests"
    echo "  gradle tasks        - Show available tasks"

    if [ -x ${WORKING_DIR}/gradlew ]; then
        echo ""
        echo "Gradle wrapper available - use './gradlew' for consistent builds"
        echo "  ./gradlew build     - Build with wrapper"
    fi

    # Check for Spring Boot
    if grep -q "spring-boot" ${WORKING_DIR}/build.gradle* 2>/dev/null; then
        echo ""
        echo "Spring Boot application detected!"
        echo "  gradle bootRun      - Start the application"
    fi
elif [ -f ${WORKING_DIR}/build.xml ]; then
    echo "=== Ant Project Detected ==="
    echo "Ant project found. Use 'ant' to build."
fi

# Display Java environment
echo ""
java-version
EOF

log_command "Setting Java startup script permissions" \
    chmod +x /etc/container/first-startup/30-java-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Java verification script..."

cat > /usr/local/bin/test-java << 'EOF'
#!/bin/bash
echo "=== Java Installation Status ==="
if command -v java &> /dev/null; then
    echo "✓ Java is installed"
    java -version 2>&1 | head -n 1 | sed 's/^/  /'
    echo "  JAVA_HOME: $JAVA_HOME"
    echo "  Binary: $(which java)"
else
    echo "✗ Java is not installed"
fi

echo ""
echo "=== Build Tools ==="
for cmd in mvn gradle ant; do
    if command -v $cmd &> /dev/null; then
        case $cmd in
            mvn)
                version=$(mvn --version 2>&1 | head -n 1)
                ;;
            gradle)
                version=$(gradle --version 2>&1 | grep "Gradle" | head -n 1)
                ;;
            ant)
                version=$(ant -version 2>&1)
                ;;
        esac
        echo "✓ $cmd: $version"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Java Tools ==="
for cmd in javac jar javadoc javap jshell; do
    if command -v $cmd &> /dev/null; then
        echo "✓ $cmd is available"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Cache Directories ==="
echo "Maven repository: ${MAVEN_USER_HOME:-/cache/maven}"
[ -d "${MAVEN_USER_HOME:-/cache/maven}/repository" ] && echo "  $(find ${MAVEN_USER_HOME:-/cache/maven}/repository -type f -name "*.jar" 2>/dev/null | wc -l) JARs cached"
echo "Gradle home: ${GRADLE_USER_HOME:-/cache/gradle}"
[ -d "${GRADLE_USER_HOME:-/cache/gradle}/caches" ] && echo "  Cache exists"
EOF

log_command "Setting test-java script permissions" \
    chmod +x /usr/local/bin/test-java

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Java installation..."

log_command "Checking Java version" \
    /usr/local/bin/java -version || log_warning "Java not installed properly"

log_command "Checking javac version" \
    /usr/local/bin/javac -version || log_warning "javac not installed properly"

log_command "Checking Maven version" \
    /usr/local/bin/mvn --version || log_warning "Maven not installed properly"

log_command "Checking Gradle version" \
    /usr/local/bin/gradle --version || log_warning "Gradle not installed properly"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Java directories..."
log_command "Final ownership fix for Java cache directories" \
    chown -R "${USER_UID}:${USER_GID}" "${MAVEN_CACHE_DIR}" "${GRADLE_HOME_DIR}" || true

# Log feature summary
# Export directory paths for feature summary (also defined in bashrc for runtime)
export JAVA_HOME="/usr/lib/jvm/default-java"
export MAVEN_CACHE_DIR="/cache/maven"
export GRADLE_HOME_DIR="/cache/gradle"

log_feature_summary \
    --feature "Java" \
    --version "${JAVA_VERSION}" \
    --tools "java,javac,maven,gradle" \
    --paths "${JAVA_HOME},${MAVEN_CACHE_DIR},${GRADLE_HOME_DIR}" \
    --env "JAVA_HOME,M2_HOME,MAVEN_HOME,MAVEN_USER_HOME,GRADLE_HOME,GRADLE_USER_HOME,MAVEN_OPTS,GRADLE_OPTS" \
    --commands "java,javac,jar,mvn,gradle,mvnc,mvnci,gwb,gwc,java-version,mvn-create,gradle-init" \
    --next-steps "Run 'test-java' to verify installation. Use 'mvn-create <groupId> <artifactId>' or 'gradle-init' to create projects."

# End logging
log_feature_end

echo ""
echo "Run 'test-java' to verify Java installation"
echo "Run 'check-build-logs.sh java' to review installation logs"
