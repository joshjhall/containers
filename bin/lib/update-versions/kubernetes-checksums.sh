#!/bin/bash
# Kubernetes Checksums Updater
#
# Description:
#   Updates checksums in lib/features/kubernetes.sh when k9s, krew, or helm versions change.
#   Called by update-versions.sh when KUBERNETES-related tool versions are updated.
#
# Usage:
#   ./kubernetes-checksums.sh <k9s_version> <krew_version> <helm_version>
#
# Example:
#   ./kubernetes-checksums.sh "0.50.16" "0.4.5" "3.19.0"

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared helpers
source "${SCRIPT_DIR}/helpers.sh"

# Target script to update
KUBERNETES_SCRIPT="lib/features/kubernetes.sh"

# ============================================================================
# k9s Checksum Updates
# ============================================================================

update_k9s_checksums() {
    local version="$1"

    log_info "Updating k9s checksums for version ${version}..."

    # k9s uses checksums.sha256 file
    local checksums
    if ! checksums=$(fetch_github_checksum_file "derailed/k9s" "v${version}" "checksums.sha256"); then
        log_error "Failed to fetch k9s checksums"
        return 1
    fi

    # Extract checksums for both architectures
    local amd64_checksum
    local arm64_checksum

    amd64_checksum=$(echo "$checksums" | extract_checksum_from_file "k9s_Linux_amd64.tar.gz")
    arm64_checksum=$(echo "$checksums" | extract_checksum_from_file "k9s_Linux_arm64.tar.gz")

    if [ -z "$amd64_checksum" ] || [ -z "$arm64_checksum" ]; then
        log_error "Failed to extract k9s checksums"
        return 1
    fi

    log_info "k9s amd64 checksum: $amd64_checksum"
    log_info "k9s arm64 checksum: $arm64_checksum"

    # Update checksums in kubernetes.sh
    update_checksum_variable "$KUBERNETES_SCRIPT" "K9S_AMD64_SHA256" "$amd64_checksum"
    update_checksum_variable "$KUBERNETES_SCRIPT" "K9S_ARM64_SHA256" "$arm64_checksum"

    # Update verification date
    update_version_comment "$KUBERNETES_SCRIPT" "# Verified on:" "$(get_current_date)"

    # Verify updates
    verify_checksum_update "$KUBERNETES_SCRIPT" "K9S_AMD64_SHA256" "$amd64_checksum"
    verify_checksum_update "$KUBERNETES_SCRIPT" "K9S_ARM64_SHA256" "$arm64_checksum"

    log_success "k9s checksums updated successfully"
}

# ============================================================================
# krew Checksum Updates
# ============================================================================

update_krew_checksums() {
    local version="$1"

    log_info "Updating krew checksums for version ${version}..."

    # krew provides individual .sha256 files for each asset
    local amd64_checksum
    local arm64_checksum

    amd64_checksum=$(fetch_github_individual_checksum "kubernetes-sigs/krew" "v${version}" "krew-linux_amd64.tar.gz")
    arm64_checksum=$(fetch_github_individual_checksum "kubernetes-sigs/krew" "v${version}" "krew-linux_arm64.tar.gz")

    if [ -z "$amd64_checksum" ] || [ -z "$arm64_checksum" ]; then
        log_error "Failed to fetch krew checksums"
        return 1
    fi

    log_info "krew amd64 checksum: $amd64_checksum"
    log_info "krew arm64 checksum: $arm64_checksum"

    # Update checksums in kubernetes.sh
    update_checksum_variable "$KUBERNETES_SCRIPT" "KREW_AMD64_SHA256" "$amd64_checksum"
    update_checksum_variable "$KUBERNETES_SCRIPT" "KREW_ARM64_SHA256" "$arm64_checksum"

    # Verify updates
    verify_checksum_update "$KUBERNETES_SCRIPT" "KREW_AMD64_SHA256" "$amd64_checksum"
    verify_checksum_update "$KUBERNETES_SCRIPT" "KREW_ARM64_SHA256" "$arm64_checksum"

    log_success "krew checksums updated successfully"
}

# ============================================================================
# Helm Checksum Updates
# ============================================================================

update_helm_checksums() {
    local version="$1"

    log_info "Updating Helm checksums for version ${version}..."

    # Helm provides individual .sha256sum files for each tarball
    local amd64_checksum
    local arm64_checksum

    # Fetch checksums from get.helm.sh
    amd64_checksum=$(curl -fsSL "https://get.helm.sh/helm-v${version}-linux-amd64.tar.gz.sha256sum" | awk '{print $1}')
    arm64_checksum=$(curl -fsSL "https://get.helm.sh/helm-v${version}-linux-arm64.tar.gz.sha256sum" | awk '{print $1}')

    if [ -z "$amd64_checksum" ] || [ -z "$arm64_checksum" ]; then
        log_error "Failed to fetch Helm checksums"
        return 1
    fi

    log_info "Helm amd64 checksum: $amd64_checksum"
    log_info "Helm arm64 checksum: $arm64_checksum"

    # Update checksums in kubernetes.sh
    update_checksum_variable "$KUBERNETES_SCRIPT" "HELM_AMD64_SHA256" "$amd64_checksum"
    update_checksum_variable "$KUBERNETES_SCRIPT" "HELM_ARM64_SHA256" "$arm64_checksum"

    # Verify updates
    verify_checksum_update "$KUBERNETES_SCRIPT" "HELM_AMD64_SHA256" "$amd64_checksum"
    verify_checksum_update "$KUBERNETES_SCRIPT" "HELM_ARM64_SHA256" "$arm64_checksum"

    log_success "Helm checksums updated successfully"
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    if [ $# -lt 3 ]; then
        log_error "Usage: $0 <k9s_version> <krew_version> <helm_version>"
        log_error "Example: $0 0.50.16 0.4.5 3.19.0"
        exit 1
    fi

    local k9s_version="$1"
    local krew_version="$2"
    local helm_version="$3"

    log_info "=========================================="
    log_info "Kubernetes Checksum Updater"
    log_info "=========================================="
    log_info "k9s version:  ${k9s_version}"
    log_info "krew version: ${krew_version}"
    log_info "Helm version: ${helm_version}"
    log_info ""

    # Check if kubernetes.sh exists
    if [ ! -f "$KUBERNETES_SCRIPT" ]; then
        log_error "Kubernetes script not found: $KUBERNETES_SCRIPT"
        exit 1
    fi

    # Update checksums
    local failed=0

    if ! update_k9s_checksums "$k9s_version"; then
        failed=$((failed + 1))
    fi

    if ! update_krew_checksums "$krew_version"; then
        failed=$((failed + 1))
    fi

    if ! update_helm_checksums "$helm_version"; then
        failed=$((failed + 1))
    fi

    if [ $failed -gt 0 ]; then
        log_error "Failed to update $failed checksum(s)"
        exit 1
    fi

    log_success "=========================================="
    log_success "All Kubernetes checksums updated!"
    log_success "=========================================="
}

# Run main function if script is executed (not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
