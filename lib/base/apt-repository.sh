#!/bin/bash
# APT repository and GPG key management
#
# Provides version-aware functions for adding apt repositories with GPG keys.
# Handles both legacy apt-key (Debian 11) and modern signed-by (Debian 12+)
# methods automatically.
#
# Usage:
#   Source this file in your script:
#     source /tmp/build-scripts/base/apt-repository.sh
#
#   Then use:
#     add_apt_repository_key "Kubernetes" \
#         "https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key" \
#         "/usr/share/keyrings/kubernetes-apt-keyring.gpg" \
#         "/etc/apt/sources.list.d/kubernetes.list" \
#         "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /"
#
# Include guard: _APT_REPOSITORY_LOADED

# Prevent multiple sourcing
if [ -n "${_APT_REPOSITORY_LOADED:-}" ]; then
    return 0
fi
_APT_REPOSITORY_LOADED=1

# Source Debian version detection
# shellcheck source=lib/base/debian-version.sh
if [ -f "/tmp/build-scripts/base/debian-version.sh" ]; then
    source "/tmp/build-scripts/base/debian-version.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/debian-version.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/debian-version.sh"
fi

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh"
fi

# ============================================================================
# add_apt_repository_key - Add an apt repository with GPG key (Debian-version-aware)
#
# Handles both legacy apt-key (Debian 11) and modern signed-by (Debian 12+)
# methods for adding GPG keys and apt repository sources.
#
# Arguments:
#   $1 - tool_name:   Human-readable name for log messages (e.g., "Kubernetes")
#   $2 - key_url:     URL to download the GPG key from
#   $3 - keyring_path: Path to store the keyring (e.g., /usr/share/keyrings/foo.gpg)
#   $4 - source_list:  Path to the sources.list.d file
#   $5 - repo_line:    Full deb line including [signed-by=...] for modern method
#   $6 - key_format:   "armored" (needs dearmor, default) or "binary" (raw .gpg)
#
# Usage:
#   add_apt_repository_key "Kubernetes" \
#       "https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key" \
#       "/usr/share/keyrings/kubernetes-apt-keyring.gpg" \
#       "/etc/apt/sources.list.d/kubernetes.list" \
#       "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /"
# ============================================================================
add_apt_repository_key() {
    local tool_name="$1"
    local key_url="$2"
    local keyring_path="$3"
    local source_list="$4"
    local repo_line="$5"
    local key_format="${6:-armored}" # "armored" (needs dearmor) or "binary"

    if ! is_debian_version 12; then
        # Legacy method for Debian 11
        log_message "Using apt-key method (Debian 11)"
        log_message "Adding ${tool_name} GPG key"
        retry_with_backoff curl -fsSL "$key_url" | apt-key add -

        # Strip signed-by from repo_line for legacy format
        local legacy_line="$repo_line"
        # Match optional leading space + signed-by= + value (stop at ] or space)
        # Handles both "[signed-by=/path]" and "[arch=amd64 signed-by=/path]"
        legacy_line=$(echo "$legacy_line" | command sed 's/ *signed-by=[^] ]*//g')
        # Clean up empty options brackets: "deb [ ] ..." -> "deb ..."
        # and "deb [arch=amd64 ] ..." -> "deb [arch=amd64] ..."
        legacy_line=$(echo "$legacy_line" | command sed 's/\[ *\] *//g; s/ *\] */] /g')

        log_command "Adding ${tool_name} repository" \
            bash -c "echo '${legacy_line}' > ${source_list}"
    else
        # Modern method for Debian 12+
        log_message "Using signed-by method (Debian 12+)"
        log_command "Creating keyrings directory" \
            mkdir -p "$(dirname "$keyring_path")"

        log_message "Adding ${tool_name} GPG key"
        if [ "$key_format" = "armored" ]; then
            retry_with_backoff curl -fsSL "$key_url" | gpg --dearmor -o "$keyring_path"
        else
            retry_with_backoff curl -fsSL "$key_url" -o "$keyring_path"
        fi

        log_command "Setting GPG key permissions" \
            chmod 644 "$keyring_path"

        log_command "Adding ${tool_name} repository" \
            bash -c "echo '${repo_line}' > ${source_list}"
    fi
}

# Export functions for use by other scripts
protected_export add_apt_repository_key
