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
GPG_KEYS_DIR="${GPG_KEYS_DIR:-${REPO_ROOT}/lib/gpg-keys}"
NODEJS_RELEASE_KEYS_REPO="${NODEJS_RELEASE_KEYS_REPO:-https://github.com/nodejs/release-keys.git}"

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
# count_keyring_keys - Print the number of public keys in a keyring directory
#
# Reads a scratch copy so gpg never writes into the source directory, and
# fails (return 1) when gpg exits non-zero or lists no keys. gpg can print
# most of a keyring's keys before failing on a damaged record, so the exit
# status must be checked, not just the `pub` count (#1410).
# ============================================================================
#
# Optional $2: parent directory for the scratch copy, so a caller's interrupt
# trap that removes that directory also removes the scratch.
count_keyring_keys() {
    local src_dir="$1"
    local scratch_parent="${2:-${TMPDIR:-/tmp}}"
    local scratch output count
    # Every caller runs this with set -e suspended, so check mktemp explicitly:
    # an empty $scratch would turn `chmod 600 "$scratch"/*` into `chmod 600 /*`
    if ! scratch=$(mktemp -d "$scratch_parent/keyring-check.XXXXXX") || [ ! -d "$scratch" ]; then
        log_error "Could not create a scratch directory under $scratch_parent"
        return 1
    fi
    cp "$src_dir"/pubring.kbx "$scratch"/ || {
        rm -rf "$scratch"
        return 1
    }
    [ -f "$src_dir/trustdb.gpg" ] && cp "$src_dir/trustdb.gpg" "$scratch"/
    chmod 700 "$scratch"
    chmod 600 "$scratch"/*

    if ! output=$(GNUPGHOME="$scratch" gpg --batch --list-keys 2>&1); then
        rm -rf "$scratch"
        log_error "gpg cannot read keyring in $src_dir:"
        printf '%s\n' "$output" | command grep '^gpg:' >&2 || true
        return 1
    fi
    rm -rf "$scratch"

    count=$(printf '%s\n' "$output" | command grep -c '^pub' || true)
    if [ "${count:-0}" -eq 0 ]; then
        log_error "Keyring in $src_dir contains no public keys"
        return 1
    fi
    echo "$count"
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
    key_count=$(command find "$keys_dir" -maxdepth 1 -name "*.asc" 2>/dev/null | command wc -l)

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
    # Checked explicitly: main runs this with set -e suspended, and an empty
    # $temp_dir would aim the clone, scratch checks, and cleanup at /
    if ! temp_dir=$(mktemp -d) || [ ! -d "$temp_dir" ]; then
        log_error "Could not create a temporary directory"
        return 1
    fi

    # Clone the official release-keys repository
    log_info "Fetching latest release-keys from GitHub..."
    if ! git clone --depth=1 "$NODEJS_RELEASE_KEYS_REPO" "$temp_dir/release-keys" &>/dev/null; then
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

    # Validate the upstream keyring BEFORE touching the committed one, so an
    # unreadable keyring can never replace a working one (#1410)
    local total_keys
    if ! total_keys=$(count_keyring_keys "$temp_dir/release-keys/gpg"); then
        log_error "Upstream Node.js keyring is unreadable — keeping existing keyring"
        cd "$REPO_ROOT"
        rm -rf "$temp_dir"
        return 1
    fi

    # Copy the full keyring (including historical keys)
    log_info "Copying keyring files..."

    # Build the new keyring in a staging directory beside the committed one
    # (same filesystem, so the final swap is a rename) and validate it there.
    # The committed keyring is not touched until the staged copy has passed,
    # so no failure or interruption can leave it empty or half-written.
    mkdir -p "$(dirname "$keyring_dir")"
    local staging previous="${keyring_dir}.old.$$"
    if ! staging=$(mktemp -d "${keyring_dir}.new.XXXXXX") || [ ! -d "$staging" ]; then
        log_error "Could not create a staging directory beside $keyring_dir — keeping existing keyring"
        cd "$REPO_ROOT"
        rm -rf "$temp_dir"
        return 1
    fi
    # On interrupt: drop the staging dir and the temp clone; if the swap below
    # had moved the existing keyring aside, put it back, otherwise drop the
    # moved-aside copy so nothing stray is left under lib/gpg-keys to commit.
    # Paths are %q-quoted because the trap string is evaluated later.
    local q_staging q_previous q_keyring q_temp
    q_staging=$(printf '%q' "$staging")
    q_previous=$(printf '%q' "$previous")
    q_keyring=$(printf '%q' "$keyring_dir")
    q_temp=$(printf '%q' "$temp_dir")
    local on_interrupt="rm -rf $q_staging; if [ -d $q_keyring ]; then rm -rf $q_previous; elif [ -d $q_previous ]; then mv $q_previous $q_keyring; fi; rm -rf $q_temp"
    # Separate traps so the exit status names the signal (128+2 / 128+15)
    # shellcheck disable=SC2064 # expand paths now; the trap outlives this scope
    trap "$on_interrupt; exit 130" INT
    # shellcheck disable=SC2064 # expand paths now; the trap outlives this scope
    trap "$on_interrupt; exit 143" TERM

    # trustdb.gpg is optional (count_keyring_keys treats it the same way);
    # copying only what upstream ships makes the result mirror upstream exactly
    local keyring_files=(pubring.kbx)
    [ -f gpg/trustdb.gpg ] && keyring_files+=(trustdb.gpg)
    local f staged_ok=true
    for f in "${keyring_files[@]}"; do
        if ! cp "gpg/$f" "$staging/" || ! cmp -s "gpg/$f" "$staging/$f"; then
            staged_ok=false
        fi
    done
    if ! chmod 700 "$staging" || ! chmod 600 "$staging"/*; then
        staged_ok=false
    fi
    # Scratch under $temp_dir, so the interrupt trap's cleanup covers it
    if [ "$staged_ok" = true ] && ! count_keyring_keys "$staging" "$temp_dir" >/dev/null; then
        staged_ok=false
    fi
    if [ "$staged_ok" != true ]; then
        log_error "Staged Node.js keyring does not match upstream or is unreadable — keeping existing keyring"
        trap - INT TERM
        rm -rf "$staging"
        cd "$REPO_ROOT"
        rm -rf "$temp_dir"
        return 1
    fi

    # Swap the validated keyring into place
    if [ -d "$keyring_dir" ] && ! mv "$keyring_dir" "$previous"; then
        log_error "Could not move the existing keyring aside — keeping it"
        trap - INT TERM
        rm -rf "$staging"
        cd "$REPO_ROOT"
        rm -rf "$temp_dir"
        return 1
    fi
    if ! mv "$staging" "$keyring_dir"; then
        log_error "Could not install the new keyring — restoring the existing one"
        if [ -d "$previous" ] && ! mv "$previous" "$keyring_dir"; then
            log_error "Restore failed — the previous keyring is at $previous; move it back to $keyring_dir by hand"
        fi
        trap - INT TERM
        rm -rf "$staging"
        cd "$REPO_ROOT"
        rm -rf "$temp_dir"
        return 1
    fi
    # Clear the moved-aside copy BEFORE dropping the trap, so an interrupt
    # here still removes it rather than leaving it under lib/gpg-keys
    rm -rf "$previous"
    trap - INT TERM

    log_info "  Total keys in keyring: $total_keys"
    echo ""

    # List active releasers (from gpg-only-active-keys directory)
    log_info "Active releasers:"
    GNUPGHOME="$temp_dir/release-keys/gpg-only-active-keys" gpg --list-keys 2>/dev/null |
        command grep "^uid" | command sed 's/uid.*\] /  - /' | command sort -u

    # Generate metadata file
    local fetch_date
    fetch_date=$(date +%Y-%m-%d)
    command cat >"$metadata_file" <<EOF
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
    actual_fingerprint=$(gpg --with-colons --show-keys "$temp_dir/hashicorp.asc" 2>/dev/null |
        command awk -F: '/^fpr:/ {print $10; exit}')

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
    actual_fingerprint=$(gpg --with-colons --show-keys "$temp_dir/google-linux-signing-key.asc" 2>/dev/null |
        command awk -F: '/^fpr:/ {print $10; exit}')

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
