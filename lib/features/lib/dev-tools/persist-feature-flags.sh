#!/bin/bash
# persist-feature-flags.sh — Write build-time feature flags to runtime config
#
# Writes /etc/container/config/enabled-features.conf so that runtime startup
# scripts can discover which features were enabled at build time.

persist_feature_flags() {
    log_command "Creating container config directory" \
        mkdir -p /etc/container/config

    command cat > /etc/container/config/enabled-features.conf << FEATURES_EOF
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

# Extra skills to install (comma-separated)
# Can be overridden at runtime via environment variable
CLAUDE_EXTRA_SKILLS_DEFAULT="${CLAUDE_EXTRA_SKILLS:-}"

# Extra agents to install (comma-separated)
# Can be overridden at runtime via environment variable
CLAUDE_EXTRA_AGENTS_DEFAULT="${CLAUDE_EXTRA_AGENTS:-}"

# Component override lists (comma-separated)
# When set, these define the FULL set of components to install (replacing defaults).
# When unset (__UNSET__ sentinel), all defaults are installed.
# When empty string, no defaults are installed.
# Can be overridden at runtime via environment variable.
CLAUDE_PLUGINS_DEFAULT="${CLAUDE_PLUGINS:-__UNSET__}"
CLAUDE_MCPS_DEFAULT="${CLAUDE_MCPS:-__UNSET__}"
CLAUDE_AGENTS_DEFAULT="${CLAUDE_AGENTS:-__UNSET__}"
CLAUDE_SKILLS_DEFAULT="${CLAUDE_SKILLS:-__UNSET__}"

# File-based configuration defaults (JSON array files)
# When set, these point to JSON files that take precedence over env var lists.
# Can be overridden at runtime via *_FILE environment variable.
CLAUDE_SKILLS_FILE_DEFAULT="${CLAUDE_SKILLS_FILE:-}"
CLAUDE_AGENTS_FILE_DEFAULT="${CLAUDE_AGENTS_FILE:-}"
CLAUDE_PLUGINS_FILE_DEFAULT="${CLAUDE_PLUGINS_FILE:-}"
CLAUDE_MCPS_FILE_DEFAULT="${CLAUDE_MCPS_FILE:-}"
CLAUDE_EXTRA_SKILLS_FILE_DEFAULT="${CLAUDE_EXTRA_SKILLS_FILE:-}"
CLAUDE_EXTRA_AGENTS_FILE_DEFAULT="${CLAUDE_EXTRA_AGENTS_FILE:-}"
CLAUDE_EXTRA_PLUGINS_FILE_DEFAULT="${CLAUDE_EXTRA_PLUGINS_FILE:-}"
CLAUDE_EXTRA_MCPS_FILE_DEFAULT="${CLAUDE_EXTRA_MCPS_FILE:-}"

# Dev tools flag (for project health check and conditional startup scripts)
INCLUDE_DEV_TOOLS=${INCLUDE_DEV_TOOLS:-false}

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
