#!/bin/bash
# Track Container Image Provenance
#
# Displays the full provenance chain for a container image including digest,
# signature status, build provenance, SBOM summary, and Rekor transparency
# log entries.
#
# Prerequisites:
#   - cosign (https://github.com/sigstore/cosign)
#   - crane (optional, for digest lookup)
#   - rekor-cli (optional, for transparency log queries)
#
# Exit codes:
#   0 - Provenance retrieved successfully
#   1 - Error or missing tools
#
# Usage:
#   ./track-provenance.sh <image-ref>
#   ./track-provenance.sh --json ghcr.io/org/repo:tag
#   ./track-provenance.sh ghcr.io/org/repo@sha256:abc123

set -euo pipefail

# Defaults
GITHUB_REPO="${VERIFY_GITHUB_REPO:-}"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
OUTPUT_JSON=false
VERBOSE=false
IMAGE_REF=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json | -j)
            OUTPUT_JSON=true
            shift
            ;;
        --repo)
            GITHUB_REPO="$2"
            shift 2
            ;;
        --verbose | -v)
            VERBOSE=true
            shift
            ;;
        --help | -h)
            echo "Usage: $0 [OPTIONS] <image-ref>"
            echo ""
            echo "Display provenance chain for a container image."
            echo ""
            echo "Options:"
            echo "  --json, -j          Output as JSON"
            echo "  --repo OWNER/REPO   GitHub repository (auto-detected from image ref)"
            echo "  --verbose, -v       Show detailed output"
            echo "  --help, -h          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 ghcr.io/myorg/containers:v1.0.0-minimal"
            echo "  $0 --json ghcr.io/myorg/containers:tag"
            echo ""
            echo "Environment:"
            echo "  VERIFY_GITHUB_REPO  Default GitHub repository (OWNER/REPO)"
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
        *)
            IMAGE_REF="$1"
            shift
            ;;
    esac
done

if [ -z "$IMAGE_REF" ]; then
    echo "Error: Image reference required." >&2
    echo "Usage: $0 [OPTIONS] <image-ref>" >&2
    exit 1
fi

# Auto-detect GitHub repo from ghcr.io image reference
if [ -z "$GITHUB_REPO" ]; then
    if [[ "$IMAGE_REF" =~ ^ghcr\.io/([^:@]+) ]]; then
        GITHUB_REPO="${BASH_REMATCH[1]}"
    else
        echo "Error: Cannot auto-detect GitHub repo from image ref." >&2
        echo "Use --repo OWNER/REPO to specify." >&2
        exit 1
    fi
fi

CERTIFICATE_IDENTITY="^https://github.com/${GITHUB_REPO}"

# Check prerequisites
if ! command -v cosign >/dev/null 2>&1; then
    echo "Error: cosign is not installed." >&2
    echo "Install: https://docs.sigstore.dev/cosign/system_config/installation/" >&2
    exit 1
fi

log() {
    if [ "$VERBOSE" = "true" ]; then
        echo "$@"
    fi
}

# Get image digest
get_digest() {
    if [[ "$IMAGE_REF" =~ @sha256: ]]; then
        /usr/bin/printf '%s' "$IMAGE_REF" | /usr/bin/sed 's/.*@//'
    elif command -v crane >/dev/null 2>&1; then
        crane digest "$IMAGE_REF" 2>/dev/null || echo "unknown"
    else
        # Fall back to cosign triangulate to infer digest
        echo "unknown (install crane for digest lookup)"
    fi
}

# Check signature status
check_signature() {
    if cosign verify \
        --certificate-identity-regexp="${CERTIFICATE_IDENTITY}" \
        --certificate-oidc-issuer="${OIDC_ISSUER}" \
        "${IMAGE_REF}" >/dev/null 2>&1; then
        echo "verified"
    else
        echo "not verified"
    fi
}

# Extract provenance attestation
get_provenance() {
    cosign verify-attestation \
        --certificate-identity-regexp="${CERTIFICATE_IDENTITY}" \
        --certificate-oidc-issuer="${OIDC_ISSUER}" \
        --type=slsaprovenance \
        "${IMAGE_REF}" 2>/dev/null || echo ""
}

# Extract SBOM attestation
get_sbom_status() {
    if cosign verify-attestation \
        --certificate-identity-regexp="${CERTIFICATE_IDENTITY}" \
        --certificate-oidc-issuer="${OIDC_ISSUER}" \
        --type=cyclonedx \
        "${IMAGE_REF}" >/dev/null 2>&1; then
        echo "attached"
    else
        echo "not found"
    fi
}

# Query Rekor transparency log
get_rekor_entry() {
    if ! command -v rekor-cli >/dev/null 2>&1; then
        echo "rekor-cli not installed"
        return 0
    fi

    local digest
    digest=$(get_digest)
    if [ "$digest" = "unknown" ] || [[ "$digest" =~ "install crane" ]]; then
        echo "digest unknown, cannot query Rekor"
        return 0
    fi

    rekor-cli search --sha "$digest" 2>/dev/null || echo "no entries found"
}

# Main
DIGEST=$(get_digest)
SIGNATURE_STATUS=$(check_signature)
SBOM_STATUS=$(get_sbom_status)

if [ "$OUTPUT_JSON" = "true" ]; then
    # JSON output
    PROVENANCE_RAW=$(get_provenance)
    REKOR_ENTRY=$(get_rekor_entry)

    # Build JSON manually to avoid jq dependency
    /usr/bin/cat <<EOF
{
  "image": "$IMAGE_REF",
  "repository": "$GITHUB_REPO",
  "digest": "$DIGEST",
  "signature": "$SIGNATURE_STATUS",
  "sbom_attestation": "$SBOM_STATUS",
  "rekor_entry": "$REKOR_ENTRY",
  "has_provenance": $([ -n "$PROVENANCE_RAW" ] && echo "true" || echo "false")
}
EOF
else
    # Human-readable output
    echo "=========================================="
    echo " Container Image Provenance"
    echo "=========================================="
    echo ""
    echo "Image:       ${IMAGE_REF}"
    echo "Repository:  ${GITHUB_REPO}"
    echo "Digest:      ${DIGEST}"
    echo ""
    echo "--- Signature ---"
    echo "Status:      ${SIGNATURE_STATUS}"
    echo "Method:      Cosign keyless (Fulcio OIDC + Rekor)"
    echo "Identity:    GitHub Actions (${GITHUB_REPO})"
    echo ""
    echo "--- SLSA Provenance ---"
    PROVENANCE_RAW=$(get_provenance)
    if [ -n "$PROVENANCE_RAW" ]; then
        echo "Status:      attached"
        if command -v jq >/dev/null 2>&1; then
            echo "$PROVENANCE_RAW" | /usr/bin/head -1 | jq -r '.payload' 2>/dev/null | base64 -d 2>/dev/null | jq -r '
                "Builder:     " + (.predicate.builder.id // "unknown"),
                "Build type:  " + (.predicateType // "unknown"),
                "Source:      " + (.predicate.invocation.configSource.uri // "unknown")
            ' 2>/dev/null || echo "  (install jq for detailed provenance)"
        else
            echo "  (install jq for detailed provenance)"
        fi
    else
        echo "Status:      not found"
    fi
    echo ""
    echo "--- SBOM Attestation ---"
    echo "Status:      ${SBOM_STATUS}"
    echo "Format:      CycloneDX"
    echo ""
    echo "--- Rekor Transparency Log ---"
    REKOR_ENTRY=$(get_rekor_entry)
    echo "Entry:       ${REKOR_ENTRY}"
    echo ""
    echo "=========================================="
fi
