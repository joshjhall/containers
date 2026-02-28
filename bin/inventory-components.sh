#!/bin/bash
# Component Inventory and Version Drift Detection
#
# Generates a component inventory for deployed containers and detects
# version drift from expected versions.
#
# Usage:
#   ./bin/inventory-components.sh [command] [options]
#
# Commands:
#   inventory    Generate component inventory from running container
#   drift        Detect version drift between containers
#   compare      Compare two inventory files
#   sbom         Generate enhanced SBOM with metadata
#
# Compliance Coverage:
#   - FedRAMP CM-8: Component inventory
#   - CMMC CM.L2-3.4.1: System component inventory
#   - CIS Control 1.4: Hardware and software asset inventory
#   - NIST CSF ID.AM-2: Software platforms and applications

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    command cat << EOF
Usage: $0 <command> [options]

Commands:
  inventory <container>     Generate component inventory
  drift <image1> <image2>   Detect version drift between images
  compare <file1> <file2>   Compare two inventory files
  sbom <container>          Generate enhanced SBOM with metadata
  expected                  Show expected versions from Dockerfile

Options:
  -o, --output <file>       Output file (default: stdout)
  -f, --format <format>     Output format: json, csv, table (default: json)
  -h, --help                Show this help message

Examples:
  $0 inventory myapp:latest
  $0 drift myapp:v1 myapp:v2
  $0 expected
  $0 sbom myapp:latest -o sbom.json
EOF
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# =============================================================================
# Inventory Functions
# =============================================================================

# Get expected versions from Dockerfile
get_expected_versions() {
    local dockerfile="$PROJECT_ROOT/Dockerfile"

    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not found at $dockerfile"
        exit 1
    fi

    # Extract ARG definitions with versions
    command grep -E "^ARG.*_VERSION=" "$dockerfile" | \
        command sed 's/ARG //' | \
        command sed 's/=/ /' | \
        while read -r name value; do
            # Remove quotes if present
            value=$(echo "$value" | command tr -d '"' | command tr -d "'")
            echo "$name $value"
        done
}

# Generate inventory from running container or image
generate_inventory() {
    local container="$1"
    local format="${2:-json}"

    log_info "Generating inventory for: $container"

    # Create temporary container if it's an image
    local temp_container=""
    if ! docker inspect "$container" --format '{{.State.Running}}' >/dev/null 2>&1; then
        temp_container="inventory-$(date +%s)"
        docker create --name "$temp_container" "$container" /bin/true >/dev/null 2>&1
        container="$temp_container"
    fi

    # System packages (Debian)
    local dpkg_list
    dpkg_list=$(docker run --rm --entrypoint dpkg-query "$container" -W -f '${Package} ${Version}\n' 2>/dev/null || echo "")

    # Language runtimes
    local python_version node_version go_version rust_version ruby_version java_version

    python_version=$(docker run --rm "$container" python3 --version 2>/dev/null | command awk '{print $2}' || echo "not installed")
    node_version=$(docker run --rm "$container" node --version 2>/dev/null | command tr -d 'v' || echo "not installed")
    go_version=$(docker run --rm "$container" go version 2>/dev/null | command awk '{print $3}' | command tr -d 'go' || echo "not installed")
    rust_version=$(docker run --rm "$container" rustc --version 2>/dev/null | command awk '{print $2}' || echo "not installed")
    ruby_version=$(docker run --rm "$container" ruby --version 2>/dev/null | command awk '{print $2}' || echo "not installed")
    java_version=$(docker run --rm "$container" java -version 2>&1 | command head -1 | command awk -F'"' '{print $2}' || echo "not installed")

    # Generate output based on format
    case "$format" in
        json)
            command cat << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "image": "$1",
  "runtimes": {
    "python": "$python_version",
    "node": "$node_version",
    "go": "$go_version",
    "rust": "$rust_version",
    "ruby": "$ruby_version",
    "java": "$java_version"
  },
  "system_packages": [
$(echo "$dpkg_list" | head -50 | while read -r pkg ver; do
    echo "    {\"name\": \"$pkg\", \"version\": \"$ver\"},"
done | sed '$ s/,$//')
  ]
}
EOF
            ;;
        csv)
            echo "component,version,type"
            echo "python,$python_version,runtime"
            echo "node,$node_version,runtime"
            echo "go,$go_version,runtime"
            echo "rust,$rust_version,runtime"
            echo "ruby,$ruby_version,runtime"
            echo "java,$java_version,runtime"
            echo "$dpkg_list" | while read -r pkg ver; do
                echo "$pkg,$ver,system"
            done
            ;;
        table)
            echo "Component Inventory for $1"
            echo "========================================"
            echo ""
            echo "Language Runtimes:"
            printf "  %-15s %s\n" "Python:" "$python_version"
            printf "  %-15s %s\n" "Node.js:" "$node_version"
            printf "  %-15s %s\n" "Go:" "$go_version"
            printf "  %-15s %s\n" "Rust:" "$rust_version"
            printf "  %-15s %s\n" "Ruby:" "$ruby_version"
            printf "  %-15s %s\n" "Java:" "$java_version"
            echo ""
            echo "System Packages (first 20):"
            echo "$dpkg_list" | command head -20 | while read -r pkg ver; do
                printf "  %-30s %s\n" "$pkg" "$ver"
            done
            ;;
    esac

    # Cleanup temp container
    if [[ -n "$temp_container" ]]; then
        docker rm "$temp_container" >/dev/null 2>&1 || true
    fi
}

# Detect version drift between two images
detect_drift() {
    local image1="$1"
    local image2="$2"

    log_info "Comparing versions between $image1 and $image2"

    # Get inventories
    local inv1 inv2
    inv1=$(generate_inventory "$image1" "csv" 2>/dev/null)
    inv2=$(generate_inventory "$image2" "csv" 2>/dev/null)

    echo ""
    echo "Version Drift Report"
    echo "===================="
    echo ""
    echo "Base: $image1"
    echo "Compare: $image2"
    echo ""

    local has_drift=false

    # Compare runtimes
    echo "Runtime Differences:"
    for runtime in python node go rust ruby java; do
        local v1 v2
        v1=$(echo "$inv1" | command grep "^$runtime," | command cut -d',' -f2)
        v2=$(echo "$inv2" | command grep "^$runtime," | command cut -d',' -f2)

        if [[ "$v1" != "$v2" ]]; then
            has_drift=true
            if [[ "$v1" == "not installed" ]]; then
                echo -e "  ${GREEN}+ $runtime: $v2${NC} (added)"
            elif [[ "$v2" == "not installed" ]]; then
                echo -e "  ${RED}- $runtime: $v1${NC} (removed)"
            else
                echo -e "  ${YELLOW}~ $runtime: $v1 -> $v2${NC}"
            fi
        fi
    done

    if [[ "$has_drift" == "false" ]]; then
        echo "  No runtime version drift detected"
    fi

    echo ""

    # Summary
    if [[ "$has_drift" == "true" ]]; then
        log_warn "Version drift detected between images"
        return 1
    else
        log_info "No significant version drift detected"
        return 0
    fi
}

# Compare two inventory files
compare_inventories() {
    local file1="$1"
    local file2="$2"

    if [[ ! -f "$file1" ]] || [[ ! -f "$file2" ]]; then
        log_error "Inventory files not found"
        exit 1
    fi

    log_info "Comparing $file1 and $file2"
    diff -u "$file1" "$file2" || true
}

# Generate enhanced SBOM with metadata
generate_sbom() {
    local container="$1"
    local output="${2:-}"

    log_info "Generating enhanced SBOM for: $container"

    # Check if trivy is available
    if ! command -v trivy >/dev/null 2>&1; then
        log_error "Trivy is required for SBOM generation"
        log_info "Install with: brew install trivy (macOS) or see https://trivy.dev"
        exit 1
    fi

    # Generate SBOM with Trivy
    if [[ -n "$output" ]]; then
        trivy image --format cyclonedx --output "$output" "$container"
        log_info "SBOM written to: $output"
    else
        trivy image --format cyclonedx "$container"
    fi
}

# Show expected versions from Dockerfile
show_expected() {
    echo "Expected Versions from Dockerfile"
    echo "================================="
    echo ""

    get_expected_versions | while read -r name value; do
        # Clean up name for display
        local display_name
        display_name=$(echo "$name" | command sed 's/_VERSION$//' | command tr '[:upper:]' '[:lower:]')
        printf "  %-20s %s\n" "$display_name:" "$value"
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        inventory)
            if [[ -z "${1:-}" ]]; then
                log_error "Container/image name required"
                usage
                exit 1
            fi
            local format="json"
            local output=""
            local container="$1"
            shift

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -f|--format)
                        format="$2"
                        shift 2
                        ;;
                    -o|--output)
                        output="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            if [[ -n "$output" ]]; then
                generate_inventory "$container" "$format" > "$output"
                log_info "Inventory written to: $output"
            else
                generate_inventory "$container" "$format"
            fi
            ;;

        drift)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                log_error "Two images required for drift detection"
                usage
                exit 1
            fi
            detect_drift "$1" "$2"
            ;;

        compare)
            if [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
                log_error "Two inventory files required for comparison"
                usage
                exit 1
            fi
            compare_inventories "$1" "$2"
            ;;

        sbom)
            if [[ -z "${1:-}" ]]; then
                log_error "Container/image name required"
                usage
                exit 1
            fi
            local container="$1"
            local output=""
            shift

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -o|--output)
                        output="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            generate_sbom "$container" "$output"
            ;;

        expected)
            show_expected
            ;;

        -h|--help|help)
            usage
            ;;

        *)
            if [[ -n "$command" ]]; then
                log_error "Unknown command: $command"
            fi
            usage
            exit 1
            ;;
    esac
}

main "$@"
