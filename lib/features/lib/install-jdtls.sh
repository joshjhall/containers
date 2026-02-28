#!/bin/bash
# Eclipse JDT Language Server Installation
#
# Description:
#   Shared installation script for Eclipse JDT Language Server (jdtls).
#   This provides Java IDE features (code completion, go-to-definition,
#   refactoring, etc.) for editors like VS Code, Neovim, and Claude Code.
#
# Usage:
#   source /tmp/build-scripts/features/lib/install-jdtls.sh
#   install_jdtls
#
# The function is idempotent - it will skip installation if jdtls is
# already present at /opt/jdtls.
#
# Requirements:
#   - Java must be installed
#   - curl and tar must be available
#
# Environment Variables:
#   JDTLS_VERSION - Override the default version (default: 1.55.0)

# ============================================================================
# Configuration
# ============================================================================

JDTLS_VERSION="1.56.0"
JDTLS_HOME="/opt/jdtls"
JDTLS_DATA_DIR="/cache/jdtls"

# ============================================================================
# Installation Function
# ============================================================================

# install_jdtls - Install Eclipse JDT Language Server
#
# This function downloads and installs jdtls from Eclipse's download server.
# Installation is idempotent - if jdtls is already installed, it returns early.
#
# Arguments:
#   None
#
# Returns:
#   0 on success or if already installed
#   1 on failure
#
install_jdtls() {
    # Check if already installed
    if [ -d "${JDTLS_HOME}" ] && [ -f "${JDTLS_HOME}/bin/jdtls" ]; then
        log_message "jdtls already installed at ${JDTLS_HOME}, skipping"
        return 0
    fi

    # Check prerequisites
    if ! command -v java &>/dev/null; then
        log_warning "Java not found, skipping jdtls installation"
        return 1
    fi

    log_message "Installing Eclipse JDT Language Server ${JDTLS_VERSION}..."

    # Fetch the directory listing to get the correct filename (timestamp varies per release)
    local base_url="https://download.eclipse.org/jdtls/milestones/${JDTLS_VERSION}"
    local filename
    filename=$(curl -fsSL "${base_url}/" 2>/dev/null | command grep -oE 'jdt-language-server-[0-9.]+-[0-9]+\.tar\.gz' | command head -1)

    if [ -z "$filename" ]; then
        log_warning "Could not find jdtls ${JDTLS_VERSION} download, skipping"
        return 1
    fi

    local download_url="${base_url}/${filename}"
    log_message "Downloading from: ${download_url}"

    # Create installation directory
    mkdir -p "${JDTLS_HOME}"

    # Download and verify via 4-tier system (TOFU — no published checksums from Eclipse)
    if curl -fsSL "${download_url}" -o /tmp/jdtls.tar.gz; then
        # Source checksum verification if available
        if [ -f /tmp/build-scripts/base/checksum-verification.sh ]; then
            source /tmp/build-scripts/base/checksum-verification.sh
            local _jdtls_verify_rc=0
            verify_download "tool" "jdtls" "$JDTLS_VERSION" "/tmp/jdtls.tar.gz" "$(dpkg --print-architecture 2>/dev/null || echo 'amd64')" || _jdtls_verify_rc=$?
            if [ "$_jdtls_verify_rc" -eq 1 ]; then
                log_warning "Verification failed for jdtls, skipping"
                rm -f /tmp/jdtls.tar.gz
                return 1
            fi
        fi
        log_message "Extracting jdtls to ${JDTLS_HOME}..."
        tar -xzf /tmp/jdtls.tar.gz -C "${JDTLS_HOME}"
        rm -f /tmp/jdtls.tar.gz

        # Create wrapper script for easier invocation
        command cat > "${JDTLS_HOME}/bin/jdtls" << 'WRAPPER'
#!/bin/bash
# Eclipse JDT Language Server wrapper script
#
# This wrapper handles the complex jdtls invocation with proper paths
# and workspace configuration.

JDTLS_HOME="/opt/jdtls"
JDTLS_DATA_DIR="${JDTLS_DATA_DIR:-/cache/jdtls}"

# Find the launcher jar
LAUNCHER=$(command find "${JDTLS_HOME}/plugins" -name 'org.eclipse.equinox.launcher_*.jar' | head -1)

if [ -z "$LAUNCHER" ]; then
    echo "Error: Could not find jdtls launcher jar" >&2
    exit 1
fi

# Determine config path based on OS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    CONFIG_PATH="${JDTLS_HOME}/config_linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    CONFIG_PATH="${JDTLS_HOME}/config_mac"
else
    CONFIG_PATH="${JDTLS_HOME}/config_linux"
fi

# Create data directory if needed
mkdir -p "${JDTLS_DATA_DIR}"

# Run jdtls
exec java \
    -Declipse.application=org.eclipse.jdt.ls.core.id1 \
    -Dosgi.bundles.defaultStartLevel=4 \
    -Declipse.product=org.eclipse.jdt.ls.core.product \
    -Dlog.level=ALL \
    -noverify \
    -Xmx1G \
    --add-modules=ALL-SYSTEM \
    --add-opens java.base/java.util=ALL-UNNAMED \
    --add-opens java.base/java.lang=ALL-UNNAMED \
    -jar "$LAUNCHER" \
    -configuration "$CONFIG_PATH" \
    -data "${JDTLS_DATA_DIR}" \
    "$@"
WRAPPER
        chmod +x "${JDTLS_HOME}/bin/jdtls"

        # Create symlink to /usr/local/bin
        ln -sf "${JDTLS_HOME}/bin/jdtls" /usr/local/bin/jdtls

        # Create data directory
        mkdir -p "${JDTLS_DATA_DIR}"
        if [ -n "${BUILD_USER:-}" ]; then
            chown -R "${BUILD_USER}:${BUILD_USER}" "${JDTLS_DATA_DIR}" 2>/dev/null || true
        fi

        log_message "jdtls ${JDTLS_VERSION} installed successfully"
        return 0
    else
        log_warning "Failed to download jdtls, skipping"
        rm -f /tmp/jdtls.tar.gz
        return 1
    fi
}

# ============================================================================
# Environment Configuration
# ============================================================================

# configure_jdtls_env - Add jdtls environment configuration
#
# Creates shell configuration for jdtls paths and aliases.
#
# Arguments:
#   None
#
configure_jdtls_env() {
    if [ ! -d "${JDTLS_HOME}" ]; then
        return 0
    fi

    # Add to bashrc.d if not already present
    if [ ! -f /etc/bashrc.d/60-jdtls.sh ]; then
        command cat > /etc/bashrc.d/60-jdtls.sh << 'BASHRC'
# Eclipse JDT Language Server environment
export JDTLS_HOME="/opt/jdtls"
export JDTLS_DATA_DIR="${JDTLS_DATA_DIR:-/cache/jdtls}"

# Alias for version check
alias jdtls-version='java -jar $(command find /opt/jdtls/plugins -name "org.eclipse.jdt.ls.core_*.jar" | head -1) --version 2>/dev/null || echo "jdtls installed at /opt/jdtls"'
BASHRC
        log_message "Created jdtls shell configuration"
    fi
}
