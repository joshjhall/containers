#!/bin/bash
# Generate SBOM (Software Bill of Materials) for Container Images
#
# Generates SBOMs in SPDX and CycloneDX formats using Syft, and optionally
# scans for vulnerabilities using Grype.
#
# Prerequisites:
#   - syft (https://github.com/anchore/syft)
#   - grype (https://github.com/anchore/grype) — optional, for vulnerability scan
#
# Exit codes:
#   0 - SBOM generated successfully
#   1 - Error or missing tools
#
# Usage:
#   ./generate-sbom.sh <image-ref>
#   ./generate-sbom.sh --format spdx-json ghcr.io/org/repo:tag
#   ./generate-sbom.sh --scan ghcr.io/org/repo:tag
#   ./generate-sbom.sh --output-dir ./sboms ghcr.io/org/repo:tag

set -euo pipefail

# Defaults
OUTPUT_DIR="."
FORMAT="all"
SCAN_VULNS=false
VERBOSE=false
IMAGE_REF=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --format|-f)
            FORMAT="$2"
            shift 2
            ;;
        --output-dir|-o)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --scan|-s)
            SCAN_VULNS=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] <image-ref>"
            echo ""
            echo "Generate SBOM for a container image."
            echo ""
            echo "Options:"
            echo "  --format, -f FORMAT     Output format: spdx-json, cyclonedx-json, table, all (default: all)"
            echo "  --output-dir, -o DIR    Output directory (default: current directory)"
            echo "  --scan, -s              Scan SBOM for vulnerabilities with Grype"
            echo "  --verbose, -v           Show detailed output"
            echo "  --help, -h              Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 ghcr.io/myorg/containers:v1.0.0-minimal"
            echo "  $0 --format spdx-json --output-dir ./sboms ghcr.io/myorg/containers:tag"
            echo "  $0 --scan ghcr.io/myorg/containers:tag"
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

# Check prerequisites
if ! command -v syft >/dev/null 2>&1; then
    echo "Error: syft is not installed." >&2
    echo "Install: https://github.com/anchore/syft#installation" >&2
    exit 1
fi

log() {
    if [ "$VERBOSE" = "true" ]; then
        echo "$@"
    fi
}

# Create output directory
/usr/bin/mkdir -p "$OUTPUT_DIR"

# Derive safe filename from image ref
SAFE_NAME=$(/usr/bin/printf '%s' "$IMAGE_REF" | /usr/bin/tr '/:@' '---')

generate_spdx() {
    local output_file="${OUTPUT_DIR}/sbom-${SAFE_NAME}-spdx.json"
    echo "Generating SPDX JSON SBOM..."
    syft "${IMAGE_REF}" -o spdx-json="${output_file}"
    echo "  Written to: ${output_file}"
}

generate_cyclonedx() {
    local output_file="${OUTPUT_DIR}/sbom-${SAFE_NAME}-cyclonedx.json"
    echo "Generating CycloneDX JSON SBOM..."
    syft "${IMAGE_REF}" -o cyclonedx-json="${output_file}"
    echo "  Written to: ${output_file}"
}

generate_table() {
    local output_file="${OUTPUT_DIR}/sbom-${SAFE_NAME}-table.txt"
    echo "Generating human-readable SBOM table..."
    syft "${IMAGE_REF}" -o table="${output_file}"
    echo "  Written to: ${output_file}"

    # Show summary
    local pkg_count
    pkg_count=$(/usr/bin/wc -l < "$output_file")
    echo "  Packages found: $((pkg_count - 1))"
}

scan_vulnerabilities() {
    if ! command -v grype >/dev/null 2>&1; then
        echo "Warning: grype is not installed, skipping vulnerability scan." >&2
        echo "Install: https://github.com/anchore/grype#installation" >&2
        return 0
    fi

    local sbom_file="${OUTPUT_DIR}/sbom-${SAFE_NAME}-cyclonedx.json"
    if [ ! -f "$sbom_file" ]; then
        # Generate CycloneDX if not already done
        generate_cyclonedx
    fi

    local vuln_file="${OUTPUT_DIR}/vulnerabilities-${SAFE_NAME}.txt"
    echo ""
    echo "Scanning SBOM for vulnerabilities..."
    grype "sbom:${sbom_file}" -o table > "$vuln_file" 2>&1 || true
    echo "  Written to: ${vuln_file}"

    # Show summary
    if [ -s "$vuln_file" ]; then
        local critical high medium
        critical=$(/usr/bin/grep -c "Critical" "$vuln_file" || true)
        high=$(/usr/bin/grep -c "High" "$vuln_file" || true)
        medium=$(/usr/bin/grep -c "Medium" "$vuln_file" || true)
        echo "  Vulnerabilities: ${critical} critical, ${high} high, ${medium} medium"
    else
        echo "  No vulnerabilities found"
    fi
}

# Main
echo "Generating SBOM for: ${IMAGE_REF}"
echo "Output directory: ${OUTPUT_DIR}"
echo ""

case "$FORMAT" in
    spdx-json|spdx)
        generate_spdx
        ;;
    cyclonedx-json|cyclonedx)
        generate_cyclonedx
        ;;
    table)
        generate_table
        ;;
    all)
        generate_spdx
        echo ""
        generate_cyclonedx
        echo ""
        generate_table
        ;;
    *)
        echo "Error: Unknown format: $FORMAT" >&2
        echo "Supported: spdx-json, cyclonedx-json, table, all" >&2
        exit 1
        ;;
esac

if [ "$SCAN_VULNS" = "true" ]; then
    scan_vulnerabilities
fi

echo ""
echo "SBOM generation complete."
