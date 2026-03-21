#!/bin/bash
# Kotlin Development Tools - LSP, Linters, and Formatters
#
# Description:
#   Installs Kotlin development tools for enhanced IDE support and code quality.
#   Includes language server, linting, static analysis, and formatting tools.
#
# Features:
#   - Kotlin Language Server: LSP support for IDE features
#   - ktlint: Kotlin linter and formatter
#   - detekt: Static code analysis for Kotlin
#   - Pre-configured for Claude Code LSP integration
#
# Tools Installed:
#   - kotlin-language-server: LSP implementation for Kotlin
#   - ktlint: Linter with built-in formatter
#   - detekt: Static analysis tool
#
# Environment Variables:
#   - KTLINT_VERSION: Version of ktlint (default: latest)
#   - DETEKT_VERSION: Version of detekt (default: latest)
#
# Prerequisites:
#   - Kotlin must be installed (INCLUDE_KOTLIN=true)
#   - Java must be installed (auto-triggered with Kotlin)
#
# Common Commands:
#   - ktlint: Check all Kotlin files
#   - ktlint -F: Format all Kotlin files
#   - detekt: Run static analysis
#   - kotlin-language-server --version: Show LSP version
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source download utilities
source /tmp/build-scripts/base/download-verify.sh

# Source cache utilities
source /tmp/build-scripts/base/cache-utils.sh

# Source path utilities for secure PATH management
source /tmp/build-scripts/base/path-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source checksum and verification utilities
source /tmp/build-scripts/base/checksum-fetch.sh
source /tmp/build-scripts/base/checksum-verification.sh

# Source GitHub release installer
source /tmp/build-scripts/features/lib/install-github-release.sh

# Source jdtls installation utilities
source /tmp/build-scripts/features/lib/install-jdtls.sh

# ============================================================================
# Version Configuration
# ============================================================================
# These versions are fetched dynamically from GitHub releases
KTLINT_VERSION="${KTLINT_VERSION:-1.8.0}"
DETEKT_VERSION="${DETEKT_VERSION:-1.23.8}"
KLS_VERSION="${KLS_VERSION:-1.3.13}"

# Validate version formats
validate_ktlint_version "$KTLINT_VERSION" || {
    log_error "Build failed due to invalid KTLINT_VERSION"
    exit 1
}
validate_detekt_version "$DETEKT_VERSION" || {
    log_error "Build failed due to invalid DETEKT_VERSION"
    exit 1
}
validate_kls_version "$KLS_VERSION" || {
    log_error "Build failed due to invalid KLS_VERSION"
    exit 1
}

# Start logging
log_feature_start "Kotlin Dev Tools" "ktlint=${KTLINT_VERSION}, detekt=${DETEKT_VERSION}"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check for Kotlin installation
if ! command -v kotlinc &>/dev/null; then
    log_error "Kotlin is required but not installed"
    log_error "Enable INCLUDE_KOTLIN=true first"
    exit 1
fi

KOTLIN_VERSION=$(kotlinc -version 2>&1 | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | command head -1)
log_message "Found Kotlin: ${KOTLIN_VERSION}"

# Check for Java installation
if ! command -v java &>/dev/null; then
    log_error "Java is required but not installed"
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies..."

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

# ============================================================================
# ktlint Installation
# ============================================================================
install_github_release "ktlint" "$KTLINT_VERSION" \
    "https://github.com/pinterest/ktlint/releases/download/${KTLINT_VERSION}" \
    "ktlint" "ktlint" \
    "calculate" "binary"

# ============================================================================
# detekt Installation
# ============================================================================
install_github_release "detekt" "$DETEKT_VERSION" \
    "https://github.com/detekt/detekt/releases/download/v${DETEKT_VERSION}" \
    "detekt-cli-${DETEKT_VERSION}.zip" "detekt-cli-${DETEKT_VERSION}.zip" \
    "calculate" "zip_to:/opt"

# Rename to standard location
if [ -d "/opt/detekt-cli-${DETEKT_VERSION}" ]; then
    log_command "Renaming detekt directory" \
        mv "/opt/detekt-cli-${DETEKT_VERSION}" /opt/detekt
fi

# Create wrapper script for detekt
command cat > /usr/local/bin/detekt << DETEKT_WRAPPER
#!/bin/bash
DETEKT_HOME="/opt/detekt"
exec java -jar "\${DETEKT_HOME}/lib/detekt-cli-${DETEKT_VERSION}-all.jar" "\$@"
DETEKT_WRAPPER
chmod +x /usr/local/bin/detekt

# ============================================================================
# Kotlin Language Server Installation
# ============================================================================
install_github_release "kotlin-language-server" "$KLS_VERSION" \
    "https://github.com/fwcd/kotlin-language-server/releases/download/${KLS_VERSION}" \
    "server.zip" "server.zip" \
    "calculate" "zip_to:/opt/kotlin-language-server"

create_symlink "/opt/kotlin-language-server/server/bin/kotlin-language-server" \
    "/usr/local/bin/kotlin-language-server" "Kotlin Language Server"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring Kotlin dev tools environment..."

log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Kotlin dev tools configuration (content in lib/bashrc/kotlin-dev-config.sh)
write_bashrc_content /etc/bashrc.d/55-kotlin-dev.sh "Kotlin dev tools configuration" \
    < /tmp/build-scripts/features/lib/bashrc/kotlin-dev-config.sh

log_command "Setting Kotlin dev bashrc permissions" \
    chmod +x /etc/bashrc.d/55-kotlin-dev.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Kotlin dev aliases and helpers..."

# Kotlin dev aliases and helpers (content in lib/bashrc/kotlin-dev-aliases.sh)
write_bashrc_content /etc/bashrc.d/55-kotlin-dev.sh "Kotlin dev aliases and helpers" \
    < /tmp/build-scripts/features/lib/bashrc/kotlin-dev-aliases.sh

# ============================================================================
# Eclipse JDT Language Server (jdtls)
# ============================================================================
# Install jdtls for Java interop and mixed Kotlin/Java projects
# This is installed idempotently - skipped if already present from java-dev
log_message "Installing Eclipse JDT Language Server for Java interop..."
install_jdtls
configure_jdtls_env

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Kotlin dev tools verification script..."

command cat > /usr/local/bin/test-kotlin-dev << 'EOF'
#!/bin/bash
echo "=== Kotlin Development Tools Status ==="

echo ""
echo "=== Linting & Formatting ==="
if command -v ktlint &>/dev/null; then
    echo "✓ ktlint is installed"
    ktlint --version 2>&1 | command sed 's/^/  /'
else
    echo "✗ ktlint is not installed"
fi

echo ""
echo "=== Static Analysis ==="
if command -v detekt &>/dev/null; then
    echo "✓ detekt is installed"
    detekt --version 2>&1 | command sed 's/^/  /'
else
    echo "✗ detekt is not installed"
fi

echo ""
echo "=== Language Servers ==="
if command -v kotlin-language-server &>/dev/null; then
    echo "✓ kotlin-language-server is installed"
    echo "  Binary: $(which kotlin-language-server)"
else
    echo "✗ kotlin-language-server is not installed"
fi

if [ -d "/opt/jdtls" ]; then
    echo "✓ jdtls (Eclipse JDT Language Server) is installed"
    echo "  For Java interop and mixed Kotlin/Java projects"
else
    echo "✗ jdtls is not installed"
fi

echo ""
echo "=== Quick Tests ==="

# Test ktlint
if command -v ktlint &>/dev/null; then
    TEMP_DIR=$(mktemp -d)
    echo 'fun main() { println("Hello") }' > "$TEMP_DIR/test.kt"
    if ktlint "$TEMP_DIR/test.kt" &>/dev/null; then
        echo "✓ ktlint can lint Kotlin files"
    else
        echo "✓ ktlint detected style issues (expected for test code)"
    fi
    command rm -rf "$TEMP_DIR"
fi

echo ""
echo "=== Helper Commands ==="
echo "  ktf              - Format Kotlin files with ktlint"
echo "  ktcheck          - Check Kotlin files with ktlint"
echo "  dkt              - Run detekt static analysis"
echo "  kotlin-dev-version - Show all tool versions"
echo "  kt-init-project  - Initialize new Kotlin project"
EOF

log_command "Setting test-kotlin-dev script permissions" \
    chmod +x /usr/local/bin/test-kotlin-dev

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Kotlin dev tools installation..."

if command -v ktlint &>/dev/null; then
    log_command "Checking ktlint version" \
        ktlint --version || log_warning "ktlint not working properly"
fi

if command -v detekt &>/dev/null; then
    log_command "Checking detekt version" \
        detekt --version || log_warning "detekt not working properly"
fi

if command -v kotlin-language-server &>/dev/null; then
    log_message "kotlin-language-server is installed"
fi

# Log feature summary
log_feature_summary \
    --feature "Kotlin Dev Tools" \
    --version "ktlint=${KTLINT_VERSION}, detekt=${DETEKT_VERSION}, kls=${KLS_VERSION}" \
    --tools "ktlint,detekt,kotlin-language-server" \
    --paths "/opt/detekt,/opt/kotlin-language-server" \
    --env "DETEKT_HOME,KLS_HOME" \
    --commands "ktlint,ktf,ktcheck,detekt,dkt,kotlin-language-server,kotlin-dev-version,kt-init-project" \
    --next-steps "Run 'test-kotlin-dev' to verify installation. Use 'kt-init-project' to set up a new Kotlin project."

# End logging
log_feature_end

echo ""
echo "Run 'test-kotlin-dev' to verify Kotlin dev tools installation"
echo "Run 'check-build-logs.sh kotlin-dev' to review installation logs"
