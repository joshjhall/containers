#!/usr/bin/env bash
# Update GPG Keys for Language Runtimes
#
# This script fetches the latest GPG keys from official sources for various
# language runtimes and updates the local keyrings with metadata tracking.
#
# Usage:
#   ./bin/update-gpg-keys.sh [language...]
#
# Languages:
#   python     - Update Python release manager GPG keys
#   nodejs     - Update Node.js release team GPG keyring
#   hashicorp  - Update HashiCorp Security GPG key (for Terraform, Vault, etc.)
#   golang     - Update Google Linux Packages Signing Key (for Go releases)
#   all        - Update all language GPG keys (default if no args)
#
# Examples:
#   ./bin/update-gpg-keys.sh python
#   ./bin/update-gpg-keys.sh nodejs python hashicorp golang
#   ./bin/update-gpg-keys.sh all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GPG_KEYS_DIR="${REPO_ROOT}/lib/gpg-keys"

# Track success/failure for final summary
UPDATED_LANGUAGES=()
FAILED_LANGUAGES=()
SKIPPED_LANGUAGES=()

# ============================================================================
# Logging Functions
# ============================================================================
log_info() {
    echo -e "\033[0;34m$1\033[0m"
}

log_success() {
    echo -e "\033[0;32m✓ $1\033[0m"
}

log_warning() {
    echo -e "\033[1;33m⚠ $1\033[0m"
}

log_error() {
    echo -e "\033[0;31m✗ $1\033[0m" >&2
}

# ============================================================================
# update_python_keys - Update Python release manager GPG keys
# ============================================================================
update_python_keys() {
    log_info "=== Updating Python GPG Keys ==="
    echo ""

    local keys_dir="${GPG_KEYS_DIR}/python/keys"
    local temp_dir
    temp_dir=$(mktemp -d)

    # Download Python GPG keys from official sources
    log_info "Fetching Python release manager GPG keys..."

    local download_failed=false

    # Thomas Wouters (Python 3.12.x, 3.13.x)
    if curl -fsSL https://github.com/Yhg1s.gpg -o "$temp_dir/thomas-wouters.asc" 2>/dev/null; then
        log_success "Downloaded Thomas Wouters GPG key"
    else
        log_warning "Failed to download Thomas Wouters GPG key"
        download_failed=true
    fi

    # Pablo Galindo Salgado (Python 3.10.x, 3.11.x)
    if curl -fsSL https://keybase.io/pablogsal/pgp_keys.asc -o "$temp_dir/pablo-galindo.asc" 2>/dev/null; then
        log_success "Downloaded Pablo Galindo GPG key"
    else
        log_warning "Failed to download Pablo Galindo GPG key"
        download_failed=true
    fi

    # Łukasz Langa (Python 3.8.x, 3.9.x)
    if curl -fsSL https://keybase.io/ambv/pgp_keys.asc -o "$temp_dir/lukasz-langa.asc" 2>/dev/null; then
        log_success "Downloaded Łukasz Langa GPG key"
    else
        log_warning "Failed to download Łukasz Langa GPG key"
        download_failed=true
    fi

    if [ "$download_failed" = true ]; then
        log_error "Some Python GPG keys failed to download"
        rm -rf "$temp_dir"
        return 1
    fi

    # Create keys directory if it doesn't exist
    mkdir -p "$keys_dir"

    # Copy keys to directory
    cp "$temp_dir"/*.asc "$keys_dir/"

    # Set secure permissions
    chmod 700 "$keys_dir"
    chmod 600 "$keys_dir"/*.asc

    # Count keys
    local key_count
    key_count=$(ls -1 "$keys_dir"/*.asc 2>/dev/null | wc -l)

    # Clean up
    rm -rf "$temp_dir"

    echo ""
    log_success "Python GPG keys updated successfully"
    log_info "  Keys directory: $keys_dir"
    log_info "  Total keys: $key_count"
    echo ""

    return 0
}

# ============================================================================
# update_nodejs_keys - Update Node.js release team GPG keyring
# ============================================================================
update_nodejs_keys() {
    log_info "=== Updating Node.js GPG Keyring ==="
    echo ""

    local keyring_dir="${GPG_KEYS_DIR}/nodejs/keyring"
    local metadata_file="${GPG_KEYS_DIR}/nodejs/keyring-metadata.json"
    local temp_dir
    temp_dir=$(mktemp -d)

    # Clone the official release-keys repository
    log_info "Fetching latest release-keys from GitHub..."
    if ! git clone --depth=1 https://github.com/nodejs/release-keys.git "$temp_dir/release-keys" &>/dev/null; then
        log_error "Failed to clone nodejs/release-keys repository"
        rm -rf "$temp_dir"
        return 1
    fi

    # Get metadata from the repository
    cd "$temp_dir/release-keys"
    local commit_hash
    local commit_date
    local commit_msg
    commit_hash=$(git log -1 --format="%H")
    commit_date=$(git log -1 --format="%ci")
    commit_msg=$(git log -1 --format="%s")

    log_info "  Latest commit: $commit_hash"
    log_info "  Commit date: $commit_date"
    echo ""

    # Copy the full keyring (including historical keys)
    log_info "Copying keyring files..."
    mkdir -p "$keyring_dir"
    cp gpg/pubring.kbx "$keyring_dir/"
    cp gpg/trustdb.gpg "$keyring_dir/"

    # Set secure permissions on keyring directory and files
    chmod 700 "$keyring_dir"
    chmod 600 "$keyring_dir"/*

    # Count keys
    local total_keys
    total_keys=$(GNUPGHOME="$temp_dir/release-keys/gpg" gpg --list-keys 2>/dev/null | grep -c "^pub" || echo "0")
    log_info "  Total keys in keyring: $total_keys"
    echo ""

    # List active releasers (from gpg-only-active-keys directory)
    log_info "Active releasers:"
    GNUPGHOME="$temp_dir/release-keys/gpg-only-active-keys" gpg --list-keys 2>/dev/null | \
        grep "^uid" | sed 's/uid.*\] /  - /' | sort -u

    # Generate metadata file
    local fetch_date
    fetch_date=$(date +%Y-%m-%d)
    cat > "$metadata_file" << EOF
{
  "source": {
    "repository": "https://github.com/nodejs/release-keys",
    "commit": "$commit_hash",
    "commit_date": "$(date -Iseconds -d "$commit_date" 2>/dev/null || date -Iseconds)",
    "commit_message": "$commit_msg"
  },
  "fetched": {
    "date": "$fetch_date",
    "by": "automated"
  },
  "keyring": {
    "total_keys": $total_keys,
    "active_releasers": 8,
    "includes_historical": true,
    "description": "Complete keyring including both active and historical Node.js release signing keys"
  },
  "active_releasers": [
    "Antoine du Hamel",
    "Juan José Arboleda",
    "Marco Ippolito",
    "Michaël Zasso",
    "Rafael Gonzaga",
    "Richard Lau",
    "Ruy Adorno",
    "Ulises Gascón"
  ],
  "usage": {
    "verification_method": "GPG signature verification",
    "signature_files": [
      "SHASUMS256.txt.sig (binary signature)",
      "SHASUMS256.txt.asc (ASCII-armored signature)"
    ],
    "supported_versions": "All Node.js versions (current, LTS, and historical releases)"
  },
  "update_instructions": {
    "manual": "Run: bin/update-gpg-keys.sh nodejs",
    "automated": "Triggered automatically when check-versions.sh detects new Node.js releases",
    "frequency": "Check for updates when new Node.js major/minor versions are released"
  }
}
EOF

    # Set secure permissions on metadata file
    chmod 600 "$metadata_file"

    # Clean up
    cd "$REPO_ROOT"
    rm -rf "$temp_dir"

    echo ""
    log_success "Node.js GPG keyring updated successfully"
    log_info "  Metadata: $metadata_file"
    log_info "  Keyring directory: $keyring_dir"
    echo ""

    return 0
}

# ============================================================================
# update_hashicorp_keys - Update HashiCorp GPG key
# ============================================================================
update_hashicorp_keys() {
    log_info "=== Updating HashiCorp GPG Key ==="
    echo ""

    local keys_dir="${GPG_KEYS_DIR}/hashicorp/keys"
    local temp_dir
    temp_dir=$(mktemp -d)

    # Download HashiCorp GPG key from official source
    log_info "Fetching HashiCorp Security GPG key..."

    local hashicorp_key_url="https://www.hashicorp.com/.well-known/pgp-key.txt"
    local expected_fingerprint="C874011F0AB405110D02105534365D9472D7468F"

    if ! curl -fsSL "$hashicorp_key_url" -o "$temp_dir/hashicorp.asc" 2>/dev/null; then
        log_error "Failed to download HashiCorp GPG key from ${hashicorp_key_url}"
        rm -rf "$temp_dir"
        return 1
    fi

    log_success "Downloaded HashiCorp GPG key"

    # Verify the fingerprint matches the expected value
    log_info "Verifying key fingerprint..."
    local actual_fingerprint
    actual_fingerprint=$(gpg --with-colons --show-keys "$temp_dir/hashicorp.asc" 2>/dev/null | \
        awk -F: '/^fpr:/ {print $10; exit}')

    if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
        log_error "GPG key fingerprint mismatch!"
        log_error "Expected: ${expected_fingerprint}"
        log_error "Got:      ${actual_fingerprint}"
        rm -rf "$temp_dir"
        return 1
    fi

    log_success "Key fingerprint verified: ${actual_fingerprint}"

    # Create keys directory if it doesn't exist
    mkdir -p "$keys_dir"

    # Copy key to directory
    cp "$temp_dir/hashicorp.asc" "$keys_dir/"

    # Set secure permissions
    chmod 700 "$keys_dir"
    chmod 600 "$keys_dir"/hashicorp.asc

    # Clean up
    rm -rf "$temp_dir"

    echo ""
    log_success "HashiCorp GPG key updated successfully"
    log_info "  Keys directory: $keys_dir"
    log_info "  Key file: hashicorp.asc"
    log_info "  Fingerprint: ${actual_fingerprint}"
    echo ""

    return 0
}

# ============================================================================
# update_golang_keys - Update Google Linux Packages Signing Key (for Go)
# ============================================================================
update_golang_keys() {
    log_info "=== Updating Go (Golang) GPG Key ==="
    echo ""

    local keys_dir="${GPG_KEYS_DIR}/golang/keys"
    local temp_dir
    temp_dir=$(mktemp -d)

    # Download Google Linux Packages Signing Key
    log_info "Fetching Google Linux Packages Signing Key..."

    local google_key_url="https://dl.google.com/linux/linux_signing_key.pub"
    local expected_fingerprint="EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796"

    if ! curl -fsSL "$google_key_url" -o "$temp_dir/google-linux-signing-key.asc" 2>/dev/null; then
        log_error "Failed to download Google signing key from ${google_key_url}"
        rm -rf "$temp_dir"
        return 1
    fi

    log_success "Downloaded Google Linux Packages Signing Key"

    # Verify the fingerprint matches the expected value
    log_info "Verifying key fingerprint..."
    local actual_fingerprint
    actual_fingerprint=$(gpg --with-colons --show-keys "$temp_dir/google-linux-signing-key.asc" 2>/dev/null | \
        awk -F: '/^fpr:/ {print $10; exit}')

    if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
        log_error "GPG key fingerprint mismatch!"
        log_error "Expected: ${expected_fingerprint}"
        log_error "Got:      ${actual_fingerprint}"
        rm -rf "$temp_dir"
        return 1
    fi

    log_success "Key fingerprint verified: ${actual_fingerprint}"

    # Create keys directory if it doesn't exist
    mkdir -p "$keys_dir"

    # Copy key to directory
    cp "$temp_dir/google-linux-signing-key.asc" "$keys_dir/"

    # Set secure permissions
    chmod 700 "$keys_dir"
    chmod 600 "$keys_dir"/google-linux-signing-key.asc

    # Clean up
    rm -rf "$temp_dir"

    echo ""
    log_success "Google Linux Packages Signing Key updated successfully"
    log_info "  Keys directory: $keys_dir"
    log_info "  Key file: google-linux-signing-key.asc"
    log_info "  Fingerprint: ${actual_fingerprint}"
    log_info "  Used for: Go (Golang) binary releases and other Google Linux packages"
    echo ""

    return 0
}

# ============================================================================
# Main Script
# ============================================================================
main() {
    local languages=("$@")

    # If no arguments or "all" specified, update all languages
    if [ ${#languages[@]} -eq 0 ] || [[ " ${languages[*]} " =~ " all " ]]; then
        languages=("python" "nodejs" "hashicorp" "golang")
    fi

    echo "=== GPG Keys Update Script ==="
    echo "Languages to update: ${languages[*]}"
    echo ""

    for lang in "${languages[@]}"; do
        case "$lang" in
            python)
                if update_python_keys; then
                    UPDATED_LANGUAGES+=("python")
                else
                    FAILED_LANGUAGES+=("python")
                fi
                ;;
            nodejs)
                if update_nodejs_keys; then
                    UPDATED_LANGUAGES+=("nodejs")
                else
                    FAILED_LANGUAGES+=("nodejs")
                fi
                ;;
            hashicorp)
                if update_hashicorp_keys; then
                    UPDATED_LANGUAGES+=("hashicorp")
                else
                    FAILED_LANGUAGES+=("hashicorp")
                fi
                ;;
            golang)
                if update_golang_keys; then
                    UPDATED_LANGUAGES+=("golang")
                else
                    FAILED_LANGUAGES+=("golang")
                fi
                ;;
            all)
                # Already handled above
                ;;
            *)
                log_warning "Unknown language: $lang (skipping)"
                SKIPPED_LANGUAGES+=("$lang")
                ;;
        esac
    done

    # Print summary
    echo "=== Update Summary ==="
    if [ ${#UPDATED_LANGUAGES[@]} -gt 0 ]; then
        log_success "Updated: ${UPDATED_LANGUAGES[*]}"
    fi
    if [ ${#FAILED_LANGUAGES[@]} -gt 0 ]; then
        log_error "Failed: ${FAILED_LANGUAGES[*]}"
    fi
    if [ ${#SKIPPED_LANGUAGES[@]} -gt 0 ]; then
        log_warning "Skipped: ${SKIPPED_LANGUAGES[*]}"
    fi
    echo ""

    # Exit with error if any updates failed
    if [ ${#FAILED_LANGUAGES[@]} -gt 0 ]; then
        return 1
    fi

    return 0
}

main "$@"
