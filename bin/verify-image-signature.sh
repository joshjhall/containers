#!/bin/bash
# Verify Container Image Signatures and Attestations
#
# Verifies Cosign signatures, SLSA provenance attestations, and SBOM
# attestations for container images built by this project's CI pipeline.
#
# Prerequisites:
#   - cosign (https://github.com/sigstore/cosign)
#
# Exit codes:
#   0 - All verifications passed
#   1 - Verification failed or missing tools
#
# Usage:
#   ./verify-image-signature.sh <image-ref>
#   ./verify-image-signature.sh ghcr.io/org/repo:tag
#   ./verify-image-signature.sh --all ghcr.io/org/repo:v1.0.0
#   ./verify-image-signature.sh --signature-only ghcr.io/org/repo:tag

set -euo pipefail

# Default configuration
GITHUB_REPO="${VERIFY_GITHUB_REPO:-}"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
CHECK_SIGNATURE=true
CHECK_PROVENANCE=true
CHECK_SBOM=true
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --signature-only)
            CHECK_PROVENANCE=false
            CHECK_SBOM=false
            shift
            ;;
        --provenance-only)
            CHECK_SIGNATURE=false
            CHECK_SBOM=false
            shift
            ;;
        --sbom-only)
            CHECK_SIGNATURE=false
            CHECK_PROVENANCE=false
            shift
            ;;
        --all)
            CHECK_SIGNATURE=true
            CHECK_PROVENANCE=true
            CHECK_SBOM=true
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
            echo "Verify container image signatures and attestations."
            echo ""
            echo "Options:"
            echo "  --all               Verify signature, provenance, and SBOM (default)"
            echo "  --signature-only    Verify Cosign signature only"
            echo "  --provenance-only   Verify SLSA provenance attestation only"
            echo "  --sbom-only         Verify SBOM attestation only"
            echo "  --repo OWNER/REPO   GitHub repository (auto-detected from image ref)"
            echo "  --verbose, -v       Show detailed output"
            echo "  --help, -h          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 ghcr.io/myorg/containers:v1.0.0-minimal"
            echo "  $0 --signature-only ghcr.io/myorg/containers:latest"
            echo "  $0 --repo myorg/containers ghcr.io/myorg/containers:v1.0.0-minimal"
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

if [ -z "${IMAGE_REF:-}" ]; then
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
check_prerequisites() {
    if ! command -v cosign >/dev/null 2>&1; then
        echo "Error: cosign is not installed." >&2
        echo "Install: https://docs.sigstore.dev/cosign/system_config/installation/" >&2
        exit 1
    fi
}

log() {
    if [ "$VERBOSE" = "true" ]; then
        echo "$@"
    fi
}

PASS_COUNT=0
FAIL_COUNT=0

verify_signature() {
    echo "Verifying Cosign signature..."
    log "  Certificate identity: ${CERTIFICATE_IDENTITY}"
    log "  OIDC issuer: ${OIDC_ISSUER}"

    if cosign verify \
        --certificate-identity-regexp="${CERTIFICATE_IDENTITY}" \
        --certificate-oidc-issuer="${OIDC_ISSUER}" \
        "${IMAGE_REF}" 2>&1 | { if [ "$VERBOSE" = "true" ]; then /usr/bin/cat; else /usr/bin/cat >/dev/null; fi; }; then
        echo "[PASS] Cosign signature verified"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "[FAIL] Cosign signature verification failed" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

verify_provenance() {
    echo "Verifying SLSA provenance attestation..."

    if cosign verify-attestation \
        --certificate-identity-regexp="${CERTIFICATE_IDENTITY}" \
        --certificate-oidc-issuer="${OIDC_ISSUER}" \
        --type=slsaprovenance \
        "${IMAGE_REF}" 2>&1 | { if [ "$VERBOSE" = "true" ]; then /usr/bin/cat; else /usr/bin/cat >/dev/null; fi; }; then
        echo "[PASS] SLSA provenance attestation verified"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "[FAIL] SLSA provenance attestation verification failed" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

verify_sbom() {
    echo "Verifying SBOM attestation..."

    if cosign verify-attestation \
        --certificate-identity-regexp="${CERTIFICATE_IDENTITY}" \
        --certificate-oidc-issuer="${OIDC_ISSUER}" \
        --type=cyclonedx \
        "${IMAGE_REF}" 2>&1 | { if [ "$VERBOSE" = "true" ]; then /usr/bin/cat; else /usr/bin/cat >/dev/null; fi; }; then
        echo "[PASS] SBOM attestation verified (CycloneDX)"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "[FAIL] SBOM attestation verification failed" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Main
check_prerequisites

echo "Verifying image: ${IMAGE_REF}"
echo "GitHub repository: ${GITHUB_REPO}"
echo ""

if [ "$CHECK_SIGNATURE" = "true" ]; then
    verify_signature
    echo ""
fi

if [ "$CHECK_PROVENANCE" = "true" ]; then
    verify_provenance
    echo ""
fi

if [ "$CHECK_SBOM" = "true" ]; then
    verify_sbom
    echo ""
fi

# Summary
echo "---"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
