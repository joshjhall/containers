#!/bin/bash
# Ruby - Dynamic programming language (Direct installation without rbenv)
#
# Description:
#   Installs Ruby directly from source without using rbenv.
#   This is simpler and more appropriate for containers where only
#   one Ruby version is needed.
#
# Features:
#   - Ruby installation from source
#   - Bundler pre-installed and configured
#   - Gem caching in /cache directory
#   - Bundle caching for faster dependency installation
#   - Development headers for native gem compilation
#
# Environment Variables:
#   RUBY_VERSION    - Ruby version to install (has a default)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source checksum verification utilities
source /tmp/build-scripts/base/download-verify.sh
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# ============================================================================
# Version Configuration
# ============================================================================
RUBY_VERSION="${RUBY_VERSION:-3.4.7}"

# Validate Ruby version format to prevent shell injection
validate_ruby_version "$RUBY_VERSION" || {
    log_error "Build failed due to invalid RUBY_VERSION"
    exit 1
}
RUBY_MAJOR=$(echo "$RUBY_VERSION" | cut -d. -f1,2)

# Start logging
log_feature_start "Ruby" "${RUBY_VERSION}"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing Ruby build dependencies..."

# Update package lists with retry logic
apt_update

# Install Ruby build dependencies with retry logic
apt_install \
    autoconf \
    bison \
    build-essential \
    libssl-dev \
    libyaml-dev \
    libreadline-dev \
    zlib1g-dev \
    libncurses5-dev \
    libffi-dev \
    libgdbm6 \
    libgdbm-dev \
    libdb-dev \
    uuid-dev \
    wget \
    ca-certificates

# ============================================================================
# Cache Configuration
# ============================================================================
# Set up cache directories
GEM_HOME_DIR="/cache/ruby/gems"
BUNDLE_PATH_DIR="/cache/ruby/bundle"

log_message "Ruby installation paths:"
log_message "  Ruby will be installed to: /usr/local"
log_message "  GEM_HOME: ${GEM_HOME_DIR}"
log_message "  BUNDLE_PATH: ${BUNDLE_PATH_DIR}"

# Create cache directories with correct ownership
log_command "Creating Ruby cache directories" \
    mkdir -p "${GEM_HOME_DIR}" "${BUNDLE_PATH_DIR}"

# Set ownership on the parent directory and all subdirectories
log_command "Setting cache directory ownership" \
    chown -R "${USER_UID}":"${USER_GID}" "/cache/ruby"

# ============================================================================
# Ruby Installation from Source
# ============================================================================
log_message "Downloading and building Ruby ${RUBY_VERSION}..."

BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

# Fetch checksum dynamically from Ruby downloads page
log_message "Fetching Ruby ${RUBY_VERSION} checksum from ruby-lang.org..."
RUBY_CHECKSUM=$(fetch_ruby_checksum "${RUBY_VERSION}")

if [ -z "$RUBY_CHECKSUM" ]; then
    log_error "Failed to fetch checksum for Ruby ${RUBY_VERSION}"
    log_error "Version may not exist or network issue. Check https://www.ruby-lang.org/en/downloads/"
    exit 1
fi

# If partial version was resolved, use the resolved version
if [ -n "${RUBY_RESOLVED_VERSION:-}" ]; then
    log_message "Resolved Ruby ${RUBY_VERSION} to ${RUBY_RESOLVED_VERSION} (latest available patch)"
    RUBY_VERSION="$RUBY_RESOLVED_VERSION"
    RUBY_MAJOR=$(echo "$RUBY_VERSION" | cut -d. -f1,2)
fi

log_message "Expected SHA256: ${RUBY_CHECKSUM}"

# Download and verify Ruby source tarball
RUBY_URL="https://cache.ruby-lang.org/pub/ruby/${RUBY_MAJOR}/ruby-${RUBY_VERSION}.tar.gz"
RUBY_TARBALL="ruby-${RUBY_VERSION}.tar.gz"

log_command "Downloading and verifying Ruby ${RUBY_VERSION} source" \
    download_and_verify \
        "${RUBY_URL}" \
        "${RUBY_TARBALL}" \
        "${RUBY_CHECKSUM}"

log_command "Extracting Ruby source" \
    tar -xzf "${RUBY_TARBALL}"

cd "ruby-${RUBY_VERSION}"

# Configure and build Ruby
log_command "Configuring Ruby build" \
    ./configure \
    --prefix=/usr/local \
    --enable-shared \
    --disable-install-doc \
    --with-opt-dir=/usr/local

log_command "Building Ruby (this may take several minutes)" \
    make -j"$(nproc)"

log_command "Installing Ruby" \
    make install

# Clean up build files
cd /
log_command "Cleaning up build directory" \
    rm -rf "$BUILD_TEMP"

# ============================================================================
# Post-installation Setup
# ============================================================================
log_message "Configuring Ruby and installing bundler..."

# Configure gem to not install documentation
cat > /usr/local/etc/gemrc << EOF
gem: --no-document
install: --no-document
update: --no-document
EOF

# Set up gem environment
export GEM_HOME="${GEM_HOME_DIR}"
export GEM_PATH="${GEM_HOME_DIR}"
export PATH="/usr/local/bin:${GEM_HOME_DIR}/bin:$PATH"

# Install bundler as the user
log_command "Installing bundler" \
    su - "${USERNAME}" -c "export GEM_HOME='${GEM_HOME_DIR}' GEM_PATH='${GEM_PATH}' && /usr/local/bin/gem install bundler"

# Configure bundler to use cache
log_command "Configuring bundler cache path" \
    /usr/local/bin/bundle config set --global path "${BUNDLE_PATH_DIR}"

log_command "Configuring bundler cache" \
    /usr/local/bin/bundle config set --global cache_path "${BUNDLE_PATH_DIR}/cache"

# ============================================================================
# System-wide Configuration
# ============================================================================
log_message "Configuring Ruby environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create Ruby configuration
write_bashrc_content /etc/bashrc.d/40-ruby.sh "Ruby environment configuration" << 'RUBY_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Ruby environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Ruby gem cache locations
export GEM_HOME="/cache/ruby/gems"
export GEM_PATH="/cache/ruby/gems"
export BUNDLE_PATH="/cache/ruby/bundle"

# Only add gem bin path if not already there
if [ -d "${GEM_HOME}/bin" ] && [[ ":$PATH:" != *":${GEM_HOME}/bin:"* ]]; then
    export PATH="${GEM_HOME}/bin:$PATH"
fi

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
RUBY_BASHRC_EOF

log_command "Setting Ruby bashrc script permissions" \
    chmod +x /etc/bashrc.d/40-ruby.sh

# ============================================================================
# Update /etc/environment with static paths
# ============================================================================
# First, read existing PATH if any
if [ -f /etc/environment ] && grep -q "^PATH=" /etc/environment; then
    # Extract existing PATH
    EXISTING_PATH=$(grep "^PATH=" /etc/environment | cut -d'"' -f2)
    # Remove the line
    log_command "Removing existing PATH from /etc/environment" \
        grep -v "^PATH=" /etc/environment > /etc/environment.tmp && mv /etc/environment.tmp /etc/environment
else
    EXISTING_PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
fi

# Add gem bin path if not already present
NEW_PATH="$EXISTING_PATH"
if [[ ":$NEW_PATH:" != *":/cache/ruby/gems/bin:"* ]]; then
    NEW_PATH="$NEW_PATH:/cache/ruby/gems/bin"
fi

# Write back
log_command "Writing updated PATH to /etc/environment" \
    bash -c "echo 'PATH=\"$NEW_PATH\"' >> /etc/environment"

# ============================================================================
# Startup Configuration
# ============================================================================

# Create startup directory if it doesn't exist
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

# Create startup script for Ruby projects
cat > /etc/container/first-startup/10-ruby-bundle.sh << 'EOF'
#!/bin/bash
# Install Ruby gems if Gemfile exists
if [ -f ${WORKING_DIR}/Gemfile ]; then
    echo "Installing Ruby gems..."
    cd ${WORKING_DIR}
    bundle install || echo "Bundle install failed, continuing..."
fi
EOF

log_command "Setting startup script permissions" \
    chmod +x /etc/container/first-startup/10-ruby-bundle.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Ruby verification script..."

cat > /usr/local/bin/test-ruby << 'EOF'
#!/bin/bash
echo "=== Ruby Installation Status ==="
if command -v ruby &> /dev/null; then
    ruby_output=$(ruby --version 2>&1)
    echo "✓ Ruby is installed: $ruby_output"
    echo "  Binary: $(which ruby)"
else
    echo "✗ Ruby is not installed"
fi

echo ""
echo "=== Ruby Tools ==="
for cmd in gem bundle rake irb; do
    if command -v $cmd &> /dev/null; then
        echo "✓ $cmd is installed at $(which $cmd)"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Ruby Environment ==="
echo "GEM_HOME: ${GEM_HOME:-not set}"
echo "GEM_PATH: ${GEM_PATH:-not set}"
echo "BUNDLE_PATH: ${BUNDLE_PATH:-not set}"

echo ""
echo "=== Installed Gems ==="
if command -v gem &> /dev/null; then
    gem list --local 2>/dev/null | head -10
    echo "..."
    total_gems=$(gem list --local 2>/dev/null | wc -l)
    echo "Total gems: $total_gems"
else
    echo "gem command not found"
fi
EOF

log_command "Setting test-ruby script permissions" \
    chmod +x /usr/local/bin/test-ruby

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Ruby installation..."

log_command "Checking Ruby version" \
    /usr/local/bin/ruby --version || log_warning "Ruby not installed properly"

log_command "Checking gem version" \
    /usr/local/bin/gem --version || log_warning "gem not installed properly"

log_command "Checking bundler version" \
    /usr/local/bin/bundle --version || log_warning "bundler not installed properly"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Ruby directories..."
log_command "Final ownership fix for Ruby cache directories" \
    chown -R "${USER_UID}":"${USER_GID}" "${GEM_HOME_DIR}" "${BUNDLE_PATH_DIR}" || true

# End logging
log_feature_end

echo ""
echo "Ruby is installed directly without rbenv"
echo "Run 'test-ruby' to verify Ruby installation"
echo "Run 'check-build-logs.sh ruby' to review installation logs"
