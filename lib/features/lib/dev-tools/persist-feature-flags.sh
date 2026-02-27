#!/bin/bash
# persist-feature-flags.sh — Write build-time feature flags to runtime config
#
# Writes /etc/container/config/enabled-features.conf so that runtime startup
# scripts can discover which features were enabled at build time.

persist_feature_flags() {
    log_command "Creating container config directory" \
        mkdir -p /etc/container/config

    cat > /etc/container/config/enabled-features.conf << FEATURES_EOF
# Auto-generated at build time - DO NOT EDIT
# This file passes build-time feature flags to runtime startup scripts
INCLUDE_PYTHON_DEV=${INCLUDE_PYTHON_DEV:-false}
INCLUDE_NODE_DEV=${INCLUDE_NODE_DEV:-false}
INCLUDE_RUST_DEV=${INCLUDE_RUST_DEV:-false}
INCLUDE_RUBY_DEV=${INCLUDE_RUBY_DEV:-false}
INCLUDE_GOLANG_DEV=${INCLUDE_GOLANG_DEV:-false}
INCLUDE_JAVA_DEV=${INCLUDE_JAVA_DEV:-false}
INCLUDE_KOTLIN_DEV=${INCLUDE_KOTLIN_DEV:-false}
INCLUDE_ANDROID_DEV=${INCLUDE_ANDROID_DEV:-false}

# Extra plugins to install (comma-separated)
# Can be overridden at runtime via environment variable
CLAUDE_EXTRA_PLUGINS_DEFAULT="${CLAUDE_EXTRA_PLUGINS:-}"

# Extra MCP servers to install (comma-separated)
# Can be overridden at runtime via environment variable
CLAUDE_EXTRA_MCPS_DEFAULT="${CLAUDE_EXTRA_MCPS:-}"

# Support tool flags (for conditional skills/agents)
INCLUDE_DOCKER=${INCLUDE_DOCKER:-false}
INCLUDE_KUBERNETES=${INCLUDE_KUBERNETES:-false}
INCLUDE_TERRAFORM=${INCLUDE_TERRAFORM:-false}
INCLUDE_AWS=${INCLUDE_AWS:-false}
INCLUDE_GCLOUD=${INCLUDE_GCLOUD:-false}
INCLUDE_CLOUDFLARE=${INCLUDE_CLOUDFLARE:-false}
FEATURES_EOF

    log_command "Setting config file permissions" \
        chmod 644 /etc/container/config/enabled-features.conf
}
