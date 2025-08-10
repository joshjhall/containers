#!/bin/bash
# Ruby Development Tools - Testing, debugging, and code quality tools
#
# Description:
#   Installs comprehensive Ruby development tools for testing, debugging,
#   code quality, and documentation. All tools are installed as gems.
#
# Features:
#   - Testing: rspec, minitest, capybara, simplecov
#   - Debugging: pry, byebug, better_errors
#   - Code Quality: rubocop, reek, brakeman
#   - Documentation: yard, rdoc
#   - Utilities: bundler-audit, solargraph (LSP)
#   - Rails tools: rails, spring
#
# Requirements:
#   - Ruby must be installed (via INCLUDE_RUBY=true)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Start logging
log_feature_start "Ruby Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check if Ruby is available
if [ ! -f "/usr/local/bin/ruby" ]; then
    log_error "Ruby not found at /usr/local/bin/ruby"
    log_error "The INCLUDE_RUBY feature must be enabled before ruby-dev tools can be installed"
    log_feature_end
    exit 1
fi

# Check if gem is available
if [ ! -f "/usr/local/bin/gem" ]; then
    log_error "gem not found at /usr/local/bin/gem"
    log_error "The INCLUDE_RUBY feature must be enabled first"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_command "Updating package lists" \
    apt-get update

log_command "Installing system dependencies for Ruby dev tools" \
    apt-get install -y --no-install-recommends \
    libxml2-dev \
    libxslt1-dev \
    libcurl4-openssl-dev \
    libpq-dev \
    libmariadb-dev \
    libsqlite3-dev \
    nodejs  # Some tools need a JS runtime

# ============================================================================
# Ruby Development Tools Installation
# ============================================================================
log_message "Installing Ruby development tools via gem..."

# Set gem paths
export GEM_HOME="/cache/ruby/gems"
export GEM_PATH="/cache/ruby/gems"
export PATH="${GEM_HOME}/bin:$PATH"

# Helper function to install gems as user
gem_install_as_user() {
    local gems="$@"
    su - ${USERNAME} -c "export GEM_HOME='${GEM_HOME}' GEM_PATH='${GEM_PATH}' && /usr/local/bin/gem install ${gems}"
}

# Testing frameworks
log_command "Installing testing frameworks" \
    gem_install_as_user rspec minitest capybara simplecov test-unit cucumber

# Debugging tools
log_command "Installing debugging tools" \
    gem_install_as_user pry pry-byebug pry-rescue pry-doc byebug better_errors binding_of_caller

# Code quality and linting
log_command "Installing code quality tools" \
    gem_install_as_user rubocop rubocop-rspec rubocop-rails rubocop-performance reek brakeman

# Documentation tools
log_command "Installing documentation tools" \
    gem_install_as_user yard yard-junk rdoc

# Development utilities
log_command "Installing development utilities" \
    gem_install_as_user bundler-audit license_finder solargraph prettier_print

# Rails and web development (optional but common)
log_command "Installing Rails development tools" \
    gem_install_as_user rails spring spring-commands-rspec guard guard-rspec

# Performance tools
log_command "Installing performance tools" \
    gem_install_as_user benchmark-ips stackprof memory_profiler

# ============================================================================
# Create symlinks for Ruby dev tools
# ============================================================================
log_message "Creating symlinks for Ruby dev tools..."

# Common Ruby dev commands that should be in PATH
for cmd in rspec rubocop reek brakeman yard pry rails spring guard solargraph; do
    if [ -f "${GEM_HOME}/bin/${cmd}" ]; then
        create_symlink "${GEM_HOME}/bin/${cmd}" "/usr/local/bin/${cmd}" "${cmd} Ruby tool"
    fi
done

# ============================================================================
# Configure system-wide environment
# ============================================================================
echo "=== Configuring system-wide Ruby dev environment ==="

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create Ruby dev tools configuration
write_bashrc_content /etc/bashrc.d/45-ruby-dev.sh "Ruby development tools configuration" << 'RUBY_DEV_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Ruby development tools configuration
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

# RSpec configuration
export SPEC_OPTS="--format documentation --color"

# Pry configuration
export PRY_THEME="solarized"

# Bundler audit configuration
export BUNDLE_AUDIT_UPDATE_ON_INSTALL=true

# Spring configuration (Rails preloader)
export SPRING_TMP_PATH="/tmp/spring"

# Ruby development aliases
alias be='bundle exec'
alias ber='bundle exec rspec'
alias bert='bundle exec rake test'
alias beru='bundle exec rubocop'
alias berg='bundle exec rails generate'
alias berc='bundle exec rails console'
alias bers='bundle exec rails server'

# RSpec aliases
alias rspec-fast='rspec --fail-fast'
alias rspec-seed='rspec --order random'

# Rubocop aliases
alias rubocop-fix='rubocop -a'
alias rubocop-fix-all='rubocop -A'

# Bundle aliases
alias bundle-outdated='bundle outdated --strict'
alias bundle-security='bundle-audit check --update'

# Helper functions
# Run tests for modified files only
rspec-changed() {
    git diff --name-only --diff-filter=AM | grep '_spec.rb$' | xargs bundle exec rspec
}

# Profile Ruby code
ruby-profile() {
    ruby -r stackprof -e "StackProf.run(mode: :cpu, out: 'tmp/stackprof.dump') { load '$1' }"
    stackprof tmp/stackprof.dump
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
RUBY_DEV_BASHRC_EOF

log_command "Setting Ruby dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/45-ruby-dev.sh

# ============================================================================
# Create helpful development templates
# ============================================================================
echo "=== Creating Ruby development templates ==="

# Create directory for templates
log_command "Creating Ruby templates directory" \
    mkdir -p /etc/ruby-dev-templates

# RSpec configuration template
cat > /etc/ruby-dev-templates/.rspec << 'EOF'
--require spec_helper
--format documentation
--color
--order random
EOF

# Rubocop configuration template
cat > /etc/ruby-dev-templates/.rubocop.yml << 'EOF'
AllCops:
  NewCops: enable
  TargetRubyVersion: 3.0
  Exclude:
    - 'db/**/*'
    - 'config/**/*'
    - 'script/**/*'
    - 'bin/**/*'
    - 'vendor/**/*'

Style/Documentation:
  Enabled: false

Metrics/BlockLength:
  Exclude:
    - 'spec/**/*'
    - 'test/**/*'

Metrics/MethodLength:
  Max: 20
EOF

# ============================================================================
# Container Startup Scripts
# ============================================================================
echo "=== Creating ruby-dev startup script ==="

log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/20-ruby-dev-setup.sh << 'EOF'
#!/bin/bash
# Ruby development tools configuration
if command -v ruby &> /dev/null; then
    echo "=== Ruby Development Tools ==="

    # Check for Ruby project indicators
    if [ -f ${WORKING_DIR}/Gemfile ] || [ -f ${WORKING_DIR}/*.gemspec ] || [ -f ${WORKING_DIR}/Rakefile ]; then
        echo "Ruby project detected!"

        # Copy templates if files don't exist
        if [ ! -f ${WORKING_DIR}/.rspec ] && command -v rspec &> /dev/null; then
            cp /etc/ruby-dev-templates/.rspec ${WORKING_DIR}/
            echo "Created .rspec configuration"
        fi

        if [ ! -f ${WORKING_DIR}/.rubocop.yml ] && command -v rubocop &> /dev/null; then
            cp /etc/ruby-dev-templates/.rubocop.yml ${WORKING_DIR}/
            echo "Created .rubocop.yml configuration"
        fi

        # Run bundle audit if Gemfile.lock exists
        if [ -f ${WORKING_DIR}/Gemfile.lock ] && command -v bundle-audit &> /dev/null; then
            echo "Running security audit..."
            bundle-audit check --update || echo "Security audit completed with warnings"
        fi
    fi

    # Show available tools
    echo ""
    echo "Ruby dev tools available:"
    echo "  Testing: rspec, minitest, cucumber"
    echo "  Debugging: pry, byebug"
    echo "  Linting: rubocop, reek, brakeman"
    echo "  Documentation: yard, rdoc"
    echo "  Rails: rails, spring"
    echo ""
    echo "Common commands:"
    echo "  be        - bundle exec"
    echo "  ber       - bundle exec rspec"
    echo "  beru      - bundle exec rubocop"
    echo "  rubocop-fix - Auto-fix rubocop issues"
fi
EOF

log_command "Setting startup script permissions" \
    chmod +x /etc/container/first-startup/20-ruby-dev-setup.sh

# ============================================================================
# Final verification
# ============================================================================
log_message "Verifying Ruby development tools installation..."

# Check key tools
log_command "Checking rspec version" \
    /usr/local/bin/rspec --version 2>/dev/null || log_warning "rspec installation failed"

log_command "Checking rubocop version" \
    /usr/local/bin/rubocop --version 2>/dev/null || log_warning "rubocop installation failed"

log_command "Checking pry version" \
    /usr/local/bin/pry --version 2>/dev/null || log_warning "pry installation failed"

log_command "Checking yard version" \
    /usr/local/bin/yard --version 2>/dev/null || log_warning "yard installation failed"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Ruby directories..."
log_command "Final ownership fix for Ruby cache directories" \
    chown -R ${USER_UID}:${USER_GID} "${GEM_HOME}" "${BUNDLE_PATH:-/cache/ruby/bundle}" || true

# End logging
log_feature_end

echo ""
echo "Run 'check-build-logs.sh ruby-development-tools' to review installation logs"
