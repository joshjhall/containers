#!/bin/bash
# Google Cloud SDK - Complete GCP development toolkit
#
# Description:
#   Installs the official Google Cloud SDK with all essential components for
#   GCP development. Includes kubectl, authentication plugins, and alpha/beta APIs.
#
# Features:
#   - gcloud CLI: Core command-line tool for Google Cloud Platform
#   - kubectl: Kubernetes command-line tool (via gcloud components)
#   - gke-gcloud-auth-plugin: GKE authentication for kubectl
#   - Alpha/Beta components: Access to preview features
#   - Helper functions for project and region management
#   - Auto-completion and credential management
#
# Components Installed:
#   - google-cloud-cli: Base SDK package
#   - gke-gcloud-auth-plugin: Kubernetes authentication
#   - kubectl: Kubernetes CLI
#   - alpha/beta: Preview command groups
#
# Environment Variables:
#   - CLOUDSDK_PYTHON: Python interpreter to use (default: python3)
#   - GOOGLE_APPLICATION_CREDENTIALS: Path to service account key (optional)
#
# Note:
#   Credentials are automatically linked from the working directory's .config/gcloud if present.
#   Run 'gcloud auth login' for interactive authentication.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for gcloud components install
source /tmp/build-scripts/base/retry-utils.sh

# Start logging
log_feature_start "Google Cloud SDK"

# ============================================================================
# Dependencies
# ============================================================================
log_message "Installing dependencies..."

# Update package lists with retry logic
apt_update

# Install required system dependencies
log_message "Installing required packages"
apt_install python3 python3-crcmod apt-transport-https ca-certificates gnupg

# ============================================================================
# Repository Configuration
# ============================================================================
log_message "Configuring Google Cloud repository..."

# Import Google Cloud public key
# Support both old (apt-key) and new (signed-by) methods for backwards compatibility
# - Debian 11 (Bullseye) and 12 (Bookworm): apt-key still available
# - Debian 13 (Trixie) and later: apt-key removed, use signed-by method

if command -v apt-key >/dev/null 2>&1; then
    # Old method for Debian 11/12 compatibility
    log_message "Using apt-key method (Debian 11/12)"
    log_command "Adding Google Cloud GPG key" \
        bash -c "command curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -"

    log_command "Adding Google Cloud SDK repository" \
        bash -c "echo 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' > /etc/apt/sources.list.d/google-cloud-sdk.list"
else
    # New method for Debian 13+ (Trixie and later)
    log_message "Using signed-by method (Debian 13+)"
    log_command "Adding Google Cloud GPG key" \
        bash -c "command curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg > /usr/share/keyrings/cloud.google.gpg"

    log_command "Setting GPG key permissions" \
        chmod go+r /usr/share/keyrings/cloud.google.gpg

    log_command "Adding Google Cloud SDK repository" \
        bash -c "echo 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' > /etc/apt/sources.list.d/google-cloud-sdk.list"
fi

# ============================================================================
# SDK Installation
# ============================================================================
log_message "Installing Google Cloud CLI..."

# Update package lists and install Cloud SDK
# Update package lists with retry logic
apt_update

log_message "Installing Google Cloud CLI"
apt_install google-cloud-cli

# ============================================================================
# Additional Components
# ============================================================================
log_message "Installing additional gcloud components..."

# Install commonly needed components with retry logic
# gcloud components install can fail due to network issues or rate limiting
if ! retry_command "Installing gcloud components" \
    gcloud components install \
        gke-gcloud-auth-plugin \
        kubectl \
        beta \
        alpha \
        --quiet; then
    log_warning "gcloud components install failed (non-fatal) - base gcloud CLI is still functional"
fi

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Google Cloud environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide gcloud configuration
write_bashrc_content /etc/bashrc.d/50-gcloud.sh "Google Cloud SDK configuration" << 'GCLOUD_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Google Cloud SDK Configuration and Helpers
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

# ----------------------------------------------------------------------------
# Google Cloud Aliases - Common gcloud shortcuts
# ----------------------------------------------------------------------------
alias gc='gcloud'
alias gcauth='gcloud auth login'
alias gcproj='gcloud config set project'
alias gcprojs='gcloud projects list'
alias gcconf='gcloud config list'
alias gccompute='gcloud compute'
alias gcssh='gcloud compute ssh'
alias gcinstances='gcloud compute instances list'
alias gck8s='gcloud container clusters'
alias gcfunc='gcloud functions'
alias gcrun='gcloud run'

# ----------------------------------------------------------------------------
# gcloud-project - Switch or display GCP project
#
# Arguments:
#   $1 - Project ID to switch to (optional)
#
# Examples:
#   gcloud-project           # Show current project and list all
#   gcloud-project my-project # Switch to my-project
# ----------------------------------------------------------------------------
gcloud-project() {
    if [ -z "$1" ]; then
        echo "Current project: $(gcloud config get-value project)"
        echo "Available projects:"
        gcloud projects list
    else
        gcloud config set project "$1"
        echo "Switched to project: $1"
    fi
}

gcloud-region() {
    if [ -z "$1" ]; then
        echo "Current region: $(gcloud config get-value compute/region)"
        echo "Current zone: $(gcloud config get-value compute/zone)"
    else
        gcloud config set compute/region "$1"
        echo "Set region to: $1"
        if [ -n "$2" ]; then
            gcloud config set compute/zone "$2"
            echo "Set zone to: $2"
        fi
    fi
}

# ----------------------------------------------------------------------------
# gcssh-quick - SSH to GCE instance with minimal typing
#
# Arguments:
#   $1 - Instance name (required)
#   $2 - Zone (optional, uses default if not specified)
#
# Example:
#   gcssh-quick web-server us-central1-a
# ----------------------------------------------------------------------------
gcssh-quick() {
    if [ -z "$1" ]; then
        echo "Usage: gcssh-quick <instance-name> [zone]"
        return 1
    fi
    local instance="$1"
    local zone="${2:-$(gcloud config get-value compute/zone)}"
    gcloud compute ssh "$instance" --zone="$zone"
}

# ----------------------------------------------------------------------------
# gcloud-resources - List all major GCP resources in current project
#
# Shows:
#   - Compute Engine instances
#   - GKE clusters
#   - Cloud Run services
#   - Cloud Functions
# ----------------------------------------------------------------------------
gcloud-resources() {
    echo "=== Compute Instances ==="
    gcloud compute instances list 2>/dev/null || echo "No instances"
    echo -e "\n=== Container Clusters ==="
    gcloud container clusters list 2>/dev/null || echo "No clusters"
    echo -e "\n=== Cloud Run Services ==="
    gcloud run services list 2>/dev/null || echo "No services"
    echo -e "\n=== Cloud Functions ==="
    gcloud functions list 2>/dev/null || echo "No functions"
}

# GCloud auto-completion is automatically enabled by the package

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
GCLOUD_BASHRC_EOF

log_command "Setting gcloud bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-gcloud.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Google Cloud startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/20-gcloud-setup.sh << EOF
#!/bin/bash
# Check for gcloud credentials
if [ ! -d ~/.config/gcloud ] && [ -d ${WORKING_DIR}/.config/gcloud ]; then
    echo "=== Google Cloud Configuration ==="
    echo "Linking workspace gcloud configuration..."
    mkdir -p ~/.config
    ln -s ${WORKING_DIR}/.config/gcloud ~/.config/gcloud
fi

# Check if gcloud is configured
if command -v gcloud &> /dev/null; then
    if gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
        echo "Google Cloud SDK is configured"
        echo "Active account: $(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
        echo "Current project: $(gcloud config get-value project 2>/dev/null || echo 'Not set')"
    else
        echo "Google Cloud SDK is installed but not authenticated"
        echo "Run 'gcloud auth login' to authenticate"
    fi
fi
EOF

log_command "Setting gcloud startup script permissions" \
    chmod +x /etc/container/first-startup/20-gcloud-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Google Cloud verification script..."

command cat > /usr/local/bin/test-gcloud << 'EOF'
#!/bin/bash
echo "=== Google Cloud SDK Status ==="
if command -v gcloud &> /dev/null; then
    echo "✓ gcloud is installed"
    echo "  Version: $(gcloud version --format='value(version)' 2>/dev/null | head -1)"
    echo "  Binary: $(which gcloud)"
else
    echo "✗ gcloud is not installed"
    exit 1
fi

echo ""
echo "=== Installed Components ==="
# Check for key components
for component in kubectl gke-gcloud-auth-plugin; do
    if command -v $component &> /dev/null; then
        echo "✓ $component is installed"
    else
        echo "✗ $component is not installed"
    fi
done

# Check alpha/beta components
if gcloud alpha --help &>/dev/null 2>&1; then
    echo "✓ alpha commands available"
else
    echo "✗ alpha commands not available"
fi

if gcloud beta --help &>/dev/null 2>&1; then
    echo "✓ beta commands available"
else
    echo "✗ beta commands not available"
fi

echo ""
echo "=== Authentication Status ==="
active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -n "$active_account" ]; then
    echo "✓ Authenticated as: $active_account"
else
    echo "✗ Not authenticated"
    echo "  Run 'gcloud auth login' to authenticate"
fi

echo ""
echo "=== Current Configuration ==="
echo "  Project: $(gcloud config get-value project 2>/dev/null || echo '[not set]')"
echo "  Region: $(gcloud config get-value compute/region 2>/dev/null || echo '[not set]')"
echo "  Zone: $(gcloud config get-value compute/zone 2>/dev/null || echo '[not set]')"

if [ -d ~/.config/gcloud ]; then
    echo "  ✓ Config directory exists"
else
    echo "  ✗ Config directory not found"
fi
EOF

log_command "Setting test-gcloud permissions" \
    chmod +x /usr/local/bin/test-gcloud

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Google Cloud SDK installation..."

log_command "Checking gcloud version" \
    gcloud version || log_warning "gcloud not installed properly"

log_command "Listing installed components" \
    gcloud components list --format="table(name,state.name)" || log_warning "Failed to list components"

# Log feature summary
log_feature_summary \
    --feature "Google Cloud SDK" \
    --tools "gcloud,kubectl,gke-gcloud-auth-plugin" \
    --paths "$HOME/.config/gcloud" \
    --env "CLOUDSDK_PYTHON,GOOGLE_APPLICATION_CREDENTIALS" \
    --commands "gcloud,kubectl,gc,gcauth,gcproj,gcloud-project,gcloud-region,gcssh-quick" \
    --next-steps "Run 'test-gcloud' to verify installation. Authenticate with 'gcloud auth login'."

# End logging
log_feature_end

echo ""
echo "Run 'test-gcloud' to verify installation"
echo "Run 'check-build-logs.sh gcloud' to review installation logs"
