#!/bin/bash
# Kotlin Compiler - JetBrains Kotlin with Native Compilation Support
#
# Description:
#   Installs the Kotlin compiler and Kotlin/Native for standalone Kotlin development.
#   Kotlin is a modern, concise programming language that runs on the JVM and can
#   also compile to native binaries via Kotlin/Native.
#
# Features:
#   - Kotlin Compiler (kotlinc): Compile Kotlin to JVM bytecode
#   - Kotlin Script (kotlinc-jvm): Run Kotlin scripts
#   - Kotlin/Native: Compile to native binaries (architecture-specific)
#   - REPL: Interactive Kotlin shell
#   - Gradle/Maven integration ready
#   - Cache optimization for Kotlin builds
#
# Tools Installed:
#   - kotlinc: Kotlin compiler for JVM
#   - kotlin: Kotlin runner
#   - kotlinc-native: Native compiler (if available for architecture)
#
# Environment Variables:
#   - KOTLIN_VERSION: Version to install (default: 2.1.0)
#   - KOTLIN_HOME: Installation directory
#   - KOTLIN_NATIVE_HOME: Native compiler directory (if installed)
#
# Prerequisites:
#   - Java must be installed (INCLUDE_JAVA=true or auto-triggered)
#
# Common Commands:
#   - kotlinc -version: Show Kotlin version
#   - kotlinc hello.kt -include-runtime -d hello.jar: Compile to JAR
#   - kotlin hello.jar: Run JAR file
#   - kotlinc -script hello.kts: Run Kotlin script
#   - kotlinc-native hello.kt -o hello: Compile to native (if available)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source version resolution for partial version support
source /tmp/build-scripts/base/version-resolution.sh
source /tmp/build-scripts/base/cache-utils.sh

# Source download utilities
source /tmp/build-scripts/base/download-verify.sh

# Source path utilities for secure PATH management
source /tmp/build-scripts/base/path-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
KOTLIN_VERSION="${KOTLIN_VERSION:-2.1.0}"

# Validate Kotlin version format to prevent shell injection
validate_kotlin_version "$KOTLIN_VERSION" || {
    log_error "Build failed due to invalid KOTLIN_VERSION"
    exit 1
}

# Resolve partial versions to full versions
if [[ "$KOTLIN_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ORIGINAL_VERSION="$KOTLIN_VERSION"
    RESOLVED_VERSION=$(resolve_kotlin_version "$KOTLIN_VERSION" 2>/dev/null || echo "$KOTLIN_VERSION")

    if [ "$ORIGINAL_VERSION" != "$RESOLVED_VERSION" ]; then
        log_message "📍 Version Resolution: $ORIGINAL_VERSION → $RESOLVED_VERSION"
        KOTLIN_VERSION="$RESOLVED_VERSION"
    fi
fi

# Start logging
log_feature_start "Kotlin" "${KOTLIN_VERSION}"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check for Java installation
if [ ! -f "/usr/lib/jvm/default-java/bin/java" ] && ! command -v java &>/dev/null; then
    log_error "Java is required but not installed"
    log_error "Enable INCLUDE_JAVA=true or INCLUDE_KOTLIN=true triggers Java automatically"
    exit 1
fi

JAVA_VERSION_OUTPUT=$(java -version 2>&1 | head -n 1)
log_message "Found Java: $JAVA_VERSION_OUTPUT"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Kotlin..."

apt_update
apt_install \
    wget \
    unzip \
    ca-certificates

# ============================================================================
# Architecture Detection
# ============================================================================
ARCH=$(dpkg --print-architecture)
log_message "Detected architecture: $ARCH"

case "$ARCH" in
    amd64)
        KOTLIN_NATIVE_ARCH="linux-x86_64"
        KOTLIN_NATIVE_AVAILABLE=true
        ;;
    arm64)
        KOTLIN_NATIVE_ARCH="linux-aarch64"
        KOTLIN_NATIVE_AVAILABLE=true
        ;;
    *)
        log_warning "Kotlin/Native not available for architecture: $ARCH"
        KOTLIN_NATIVE_AVAILABLE=false
        ;;
esac

# ============================================================================
# Kotlin Compiler Installation
# ============================================================================
log_message "Installing Kotlin ${KOTLIN_VERSION}..."

KOTLIN_URL="https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VERSION}/kotlin-compiler-${KOTLIN_VERSION}.zip"
KOTLIN_HOME="/opt/kotlin"

# Create installation directory
log_command "Creating Kotlin installation directory" \
    mkdir -p "${KOTLIN_HOME}"

# Download Kotlin compiler
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

log_message "Downloading Kotlin compiler from ${KOTLIN_URL}..."
retry_with_backoff wget -q "${KOTLIN_URL}" -O kotlin-compiler.zip || {
    log_error "Failed to download Kotlin compiler"
    exit 1
}

# Extract Kotlin
log_command "Extracting Kotlin compiler" \
    unzip -q kotlin-compiler.zip

# Move to installation directory
log_command "Installing Kotlin to ${KOTLIN_HOME}" \
    cp -r kotlinc/* "${KOTLIN_HOME}/"

# ============================================================================
# Kotlin/Native Installation (if available)
# ============================================================================
KOTLIN_NATIVE_HOME=""
if [ "$KOTLIN_NATIVE_AVAILABLE" = true ]; then
    log_message "Installing Kotlin/Native for ${KOTLIN_NATIVE_ARCH}..."

    KOTLIN_NATIVE_URL="https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VERSION}/kotlin-native-${KOTLIN_NATIVE_ARCH}-${KOTLIN_VERSION}.tar.gz"
    KOTLIN_NATIVE_HOME="/opt/kotlin-native"

    # Try to download Kotlin/Native (may not be available for all versions)
    if retry_with_backoff wget -q "${KOTLIN_NATIVE_URL}" -O kotlin-native.tar.gz 2>/dev/null; then
        log_command "Creating Kotlin/Native directory" \
            mkdir -p "${KOTLIN_NATIVE_HOME}"

        log_command "Extracting Kotlin/Native" \
            tar -xzf kotlin-native.tar.gz --strip-components=1 -C "${KOTLIN_NATIVE_HOME}"

        log_message "Kotlin/Native installed successfully"
    else
        log_warning "Kotlin/Native not available for version ${KOTLIN_VERSION} on ${KOTLIN_NATIVE_ARCH}"
        log_warning "Skipping Kotlin/Native installation"
        KOTLIN_NATIVE_HOME=""
    fi
fi

# Clean up temp directory
cd /
rm -rf "$BUILD_TEMP"

# ============================================================================
# Create Symlinks
# ============================================================================
log_message "Creating Kotlin symlinks..."

for cmd in kotlin kotlinc kotlin-dce-js; do
    if [ -f "${KOTLIN_HOME}/bin/${cmd}" ]; then
        create_symlink "${KOTLIN_HOME}/bin/${cmd}" "/usr/local/bin/${cmd}" "${cmd} tool"
    fi
done

if [ -n "$KOTLIN_NATIVE_HOME" ] && [ -f "${KOTLIN_NATIVE_HOME}/bin/kotlinc-native" ]; then
    create_symlink "${KOTLIN_NATIVE_HOME}/bin/kotlinc-native" "/usr/local/bin/kotlinc-native" "Kotlin/Native compiler"
    create_symlink "${KOTLIN_NATIVE_HOME}/bin/cinterop" "/usr/local/bin/cinterop" "C interop tool"
    create_symlink "${KOTLIN_NATIVE_HOME}/bin/klib" "/usr/local/bin/klib" "Kotlin library tool"
fi

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring Kotlin cache directories..."

KOTLIN_CACHE_DIR="/cache/kotlin"

log_message "Kotlin cache paths:"
log_message "  Kotlin: ${KOTLIN_CACHE_DIR}"

create_cache_directories "${KOTLIN_CACHE_DIR}"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide Kotlin environment..."

log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Kotlin environment configuration (content in lib/bashrc/kotlin-env.sh)
write_bashrc_content /etc/bashrc.d/50-kotlin.sh "Kotlin environment configuration" \
    < /tmp/build-scripts/features/lib/bashrc/kotlin-env.sh

log_command "Setting Kotlin bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-kotlin.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Kotlin aliases and helpers..."

# Kotlin aliases and helpers (content in lib/bashrc/kotlin-aliases.sh)
write_bashrc_content /etc/bashrc.d/50-kotlin.sh "Kotlin aliases and helpers" \
    < /tmp/build-scripts/features/lib/bashrc/kotlin-aliases.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Kotlin startup script..."

log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/30-kotlin-setup.sh << 'EOF'
#!/bin/bash
# Kotlin development environment setup

# Check for Kotlin projects
if [ -f ${WORKING_DIR}/build.gradle.kts ]; then
    echo "=== Kotlin Gradle Project Detected ==="
    echo "Kotlin project with Gradle found. Common commands:"
    echo "  gradle build        - Build project"
    echo "  gradle test         - Run tests"
    echo "  gradle run          - Run application"

    if [ -x ${WORKING_DIR}/gradlew ]; then
        echo ""
        echo "Gradle wrapper available - use './gradlew' for consistent builds"
    fi
elif [ -f ${WORKING_DIR}/pom.xml ] && grep -q "kotlin" ${WORKING_DIR}/pom.xml 2>/dev/null; then
    echo "=== Kotlin Maven Project Detected ==="
    echo "Kotlin project with Maven found. Common commands:"
    echo "  mvn compile         - Compile project"
    echo "  mvn test            - Run tests"
    echo "  mvn package         - Package application"
fi

# Display Kotlin environment
echo ""
kotlin-version 2>/dev/null || {
    echo "Kotlin: $(kotlinc -version 2>&1)"
}
EOF

log_command "Setting Kotlin startup script permissions" \
    chmod +x /etc/container/first-startup/30-kotlin-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Kotlin verification script..."

command cat > /usr/local/bin/test-kotlin << 'EOF'
#!/bin/bash
echo "=== Kotlin Installation Status ==="
if command -v kotlinc &> /dev/null; then
    echo "✓ Kotlin is installed"
    kotlinc -version 2>&1 | head -n 1 | command sed 's/^/  /'
    echo "  KOTLIN_HOME: ${KOTLIN_HOME:-/opt/kotlin}"
    echo "  Binary: $(which kotlinc)"
else
    echo "✗ Kotlin is not installed"
fi

echo ""
echo "=== Kotlin Tools ==="
for cmd in kotlin kotlinc kotlinc-native cinterop klib; do
    if command -v $cmd &> /dev/null; then
        echo "✓ $cmd is available"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Java Environment ==="
if command -v java &> /dev/null; then
    java -version 2>&1 | head -n 1
else
    echo "Java not found (required for Kotlin/JVM)"
fi

echo ""
echo "=== Quick Test ==="
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
echo 'fun main() { println("Kotlin works!") }' > test.kt
if kotlinc test.kt -include-runtime -d test.jar 2>/dev/null; then
    result=$(kotlin test.jar 2>/dev/null)
    if [ "$result" = "Kotlin works!" ]; then
        echo "✓ Kotlin compilation and execution works"
    else
        echo "✗ Kotlin execution failed"
    fi
else
    echo "✗ Kotlin compilation failed"
fi
cd /
command rm -rf "$TEMP_DIR"

echo ""
echo "=== Cache Directory ==="
echo "Kotlin: ${KOTLIN_CACHE_DIR:-/cache/kotlin}"
[ -d "${KOTLIN_CACHE_DIR:-/cache/kotlin}" ] && echo "  Directory exists"
EOF

log_command "Setting test-kotlin script permissions" \
    chmod +x /usr/local/bin/test-kotlin

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Kotlin installation..."

log_command "Checking Kotlin version" \
    /usr/local/bin/kotlinc -version || log_warning "Kotlin not installed properly"

if [ -n "$KOTLIN_NATIVE_HOME" ]; then
    log_command "Checking Kotlin/Native version" \
        /usr/local/bin/kotlinc-native -version || log_warning "Kotlin/Native not installed properly"
fi

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Kotlin directories..."
log_command "Final ownership fix for Kotlin cache directories" \
    chown -R "${USER_UID}:${USER_GID}" "${KOTLIN_CACHE_DIR}" || true

# Log feature summary
export KOTLIN_HOME="/opt/kotlin"
export KOTLIN_CACHE_DIR="/cache/kotlin"

NATIVE_MSG=""
if [ -n "$KOTLIN_NATIVE_HOME" ]; then
    NATIVE_MSG=",kotlinc-native,cinterop"
fi

log_feature_summary \
    --feature "Kotlin" \
    --version "${KOTLIN_VERSION}" \
    --tools "kotlinc,kotlin${NATIVE_MSG}" \
    --paths "${KOTLIN_HOME},${KOTLIN_CACHE_DIR}" \
    --env "KOTLIN_HOME,KOTLIN_NATIVE_HOME,KOTLIN_CACHE_DIR" \
    --commands "kotlinc,kotlin,kt,ktc,kts,kotlin-version,kt-compile,kt-run,kt-native" \
    --next-steps "Run 'test-kotlin' to verify installation. Use 'kt-compile' or 'kt-run' for quick compilation."

# End logging
log_feature_end

echo ""
echo "Run 'test-kotlin' to verify Kotlin installation"
echo "Run 'check-build-logs.sh kotlin' to review installation logs"
