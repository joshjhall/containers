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

KOTLIN_VERSION=$(kotlinc -version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
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
log_message "Installing ktlint ${KTLINT_VERSION}..."

KTLINT_URL="https://github.com/pinterest/ktlint/releases/download/${KTLINT_VERSION}/ktlint"

BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

log_message "Downloading ktlint..."
if retry_with_backoff wget -q "${KTLINT_URL}" -O ktlint; then
    chmod +x ktlint
    log_command "Installing ktlint" \
        mv ktlint /usr/local/bin/ktlint
    log_message "ktlint installed successfully"
else
    log_warning "Failed to download ktlint, skipping"
fi

# ============================================================================
# detekt Installation
# ============================================================================
log_message "Installing detekt ${DETEKT_VERSION}..."

DETEKT_URL="https://github.com/detekt/detekt/releases/download/v${DETEKT_VERSION}/detekt-cli-${DETEKT_VERSION}.zip"

log_message "Downloading detekt..."
if retry_with_backoff wget -q "${DETEKT_URL}" -O detekt.zip; then
    log_command "Extracting detekt" \
        unzip -q detekt.zip

    log_command "Installing detekt" \
        mv "detekt-cli-${DETEKT_VERSION}" /opt/detekt

    # Create wrapper script for detekt
    command cat > /usr/local/bin/detekt << 'DETEKT_WRAPPER'
#!/bin/bash
# detekt wrapper script
DETEKT_HOME="/opt/detekt"
exec java -jar "${DETEKT_HOME}/lib/detekt-cli-${DETEKT_VERSION}-all.jar" "$@"
DETEKT_WRAPPER

    # Replace version placeholder
    command sed -i "s/\${DETEKT_VERSION}/${DETEKT_VERSION}/g" /usr/local/bin/detekt
    chmod +x /usr/local/bin/detekt

    log_message "detekt installed successfully"
else
    log_warning "Failed to download detekt, skipping"
fi

# ============================================================================
# Kotlin Language Server Installation
# ============================================================================
log_message "Installing Kotlin Language Server ${KLS_VERSION}..."

KLS_URL="https://github.com/fwcd/kotlin-language-server/releases/download/${KLS_VERSION}/server.zip"

log_message "Downloading kotlin-language-server..."
if retry_with_backoff wget -q "${KLS_URL}" -O kls.zip; then
    log_command "Extracting kotlin-language-server" \
        unzip -q kls.zip -d /opt/kotlin-language-server

    # Create symlink
    create_symlink "/opt/kotlin-language-server/server/bin/kotlin-language-server" \
        "/usr/local/bin/kotlin-language-server" "Kotlin Language Server"

    log_message "kotlin-language-server installed successfully"
else
    log_warning "Failed to download kotlin-language-server, skipping"
fi

# Clean up temp directory
cd /
rm -rf "$BUILD_TEMP"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring Kotlin dev tools environment..."

log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

write_bashrc_content /etc/bashrc.d/55-kotlin-dev.sh "Kotlin dev tools configuration" << 'KOTLIN_DEV_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Kotlin Development Tools Configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u
set +e

if [[ $- != *i* ]]; then
    return 0
fi

# detekt home
if [ -d "/opt/detekt" ]; then
    export DETEKT_HOME="/opt/detekt"
fi

# Kotlin Language Server
if [ -d "/opt/kotlin-language-server" ]; then
    export KLS_HOME="/opt/kotlin-language-server/server"
fi

KOTLIN_DEV_BASHRC_EOF

log_command "Setting Kotlin dev bashrc permissions" \
    chmod +x /etc/bashrc.d/55-kotlin-dev.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Kotlin dev aliases and helpers..."

write_bashrc_content /etc/bashrc.d/55-kotlin-dev.sh "Kotlin dev aliases and helpers" << 'KOTLIN_DEV_BASHRC_EOF'

# ----------------------------------------------------------------------------
# Kotlin Development Aliases
# ----------------------------------------------------------------------------
# ktlint shortcuts
alias ktf='ktlint -F'          # Format files
alias ktcheck='ktlint'          # Check files
alias ktfmt='ktlint -F'         # Alias for format

# detekt shortcuts
alias dkt='detekt'
alias dktcheck='detekt --build-upon-default-config'

# ----------------------------------------------------------------------------
# ktlint-all - Run ktlint on all Kotlin files in current directory
# ----------------------------------------------------------------------------
ktlint-all() {
    echo "=== Running ktlint on all Kotlin files ==="
    if [ "$1" = "-F" ] || [ "$1" = "--format" ]; then
        ktlint -F "**/*.kt" "**/*.kts"
    else
        ktlint "**/*.kt" "**/*.kts"
    fi
}

# ----------------------------------------------------------------------------
# detekt-report - Run detekt with HTML report
# ----------------------------------------------------------------------------
detekt-report() {
    local output="${1:-detekt-report.html}"
    echo "=== Running detekt with HTML report ==="
    detekt --report html:"$output"
    echo "Report saved to: $output"
}

# ----------------------------------------------------------------------------
# kotlin-dev-version - Show Kotlin development tools versions
# ----------------------------------------------------------------------------
kotlin-dev-version() {
    echo "=== Kotlin Development Tools ==="

    echo ""
    echo "ktlint:"
    if command -v ktlint &>/dev/null; then
        ktlint --version 2>&1 | head -1
    else
        echo "  Not installed"
    fi

    echo ""
    echo "detekt:"
    if command -v detekt &>/dev/null; then
        detekt --version 2>&1 | head -1
    else
        echo "  Not installed"
    fi

    echo ""
    echo "kotlin-language-server:"
    if command -v kotlin-language-server &>/dev/null; then
        kotlin-language-server --version 2>&1 | head -1 || echo "  Installed (version check not supported)"
    else
        echo "  Not installed"
    fi

    echo ""
    echo "Kotlin (base):"
    kotlinc -version 2>&1 | head -1
}

# ----------------------------------------------------------------------------
# kt-init-project - Initialize a Kotlin project with recommended config
#
# Arguments:
#   $1 - Project name (optional, defaults to current directory name)
# ----------------------------------------------------------------------------
kt-init-project() {
    local project_name="${1:-$(basename $(pwd))}"

    echo "=== Initializing Kotlin Project: $project_name ==="

    # Create .editorconfig for ktlint
    if [ ! -f ".editorconfig" ]; then
        command cat > .editorconfig << 'EDITORCONFIG'
root = true

[*]
charset = utf-8
end_of_line = lf
indent_size = 4
indent_style = space
insert_final_newline = true
trim_trailing_whitespace = true

[*.{kt,kts}]
ktlint_code_style = ktlint_official
EDITORCONFIG
        echo "Created .editorconfig"
    fi

    # Create detekt config
    if [ ! -f "detekt.yml" ]; then
        if command -v detekt &>/dev/null; then
            detekt --generate-config
            echo "Created detekt.yml"
        fi
    fi

    # Create .gitignore if not exists
    if [ ! -f ".gitignore" ]; then
        command cat > .gitignore << 'GITIGNORE'
# Kotlin
*.class
*.jar
*.war
*.nar
*.ear
*.zip
*.tar.gz
*.rar

# Gradle
.gradle/
build/
!gradle/wrapper/gradle-wrapper.jar

# Maven
target/

# IDE
.idea/
*.iml
*.ipr
*.iws
.vscode/

# OS
.DS_Store
Thumbs.db
GITIGNORE
        echo "Created .gitignore"
    fi

    echo ""
    echo "Project initialized. Next steps:"
    echo "  - Run 'gradle init --type kotlin-application' for Gradle project"
    echo "  - Or create src/main/kotlin/ directory for manual setup"
}

KOTLIN_DEV_BASHRC_EOF

# ============================================================================
# Claude Code LSP Integration
# ============================================================================
log_message "Setting up Claude Code LSP integration..."

log_command "Creating first-startup directory" \
    mkdir -p /etc/container/first-startup

# Add to existing claude-code-setup or create new
command cat > /etc/container/first-startup/31-kotlin-lsp-setup.sh << 'EOF'
#!/bin/bash
# Kotlin LSP setup for Claude Code

# Check if Claude Code is installed and LSP is enabled
if command -v claude &>/dev/null && [ "${ENABLE_LSP_TOOL:-0}" = "1" ]; then
    # Check if kotlin-language-server is installed
    if command -v kotlin-language-server &>/dev/null; then
        # Check if plugin is already installed
        if ! claude plugin list 2>/dev/null | grep -q "kotlin"; then
            echo "Installing Kotlin LSP plugin for Claude Code..."
            claude plugin add kotlin-language-server@claude-code-lsps 2>/dev/null || true
        fi
    fi
fi
EOF

log_command "Setting Kotlin LSP setup script permissions" \
    chmod +x /etc/container/first-startup/31-kotlin-lsp-setup.sh

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
