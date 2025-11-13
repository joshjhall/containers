#!/usr/bin/env bash
# Production Image Size Comparison Script
#
# This script builds dev and production variants of the same configuration
# and compares their sizes to show the space savings.
#
# Usage:
#   ./compare-sizes.sh [preset]
#
# Presets: minimal, python, node, multi (default: all)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKERFILE="${CONTAINERS_DIR}/Dockerfile"

# Test project name
PROJECT_NAME="size-test"

# Function to print colored messages
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Function to format bytes
format_bytes() {
    local bytes=$1

    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$(( bytes / 1024 ))KB"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$(( bytes / 1048576 ))MB"
    else
        echo "$(( bytes / 1073741824 ))GB"
    fi
}

# Function to get image size in bytes
get_image_size() {
    local image_tag="$1"
    docker inspect --format='{{.Size}}' "$image_tag" 2>/dev/null || echo "0"
}

# Function to build dev variant
build_dev() {
    local preset="$1"
    local tag="${PROJECT_NAME}:${preset}-dev"

    log_info "Building dev variant: ${preset}"

    local build_args=(
        "--build-arg" "PROJECT_NAME=${PROJECT_NAME}"
        "--build-arg" "BASE_IMAGE=debian:bookworm"
        "--build-arg" "ENABLE_PASSWORDLESS_SUDO=true"
        "--build-arg" "INCLUDE_DEV_TOOLS=true"
    )

    case "$preset" in
        python)
            build_args+=(
                "--build-arg" "INCLUDE_PYTHON=true"
                "--build-arg" "INCLUDE_PYTHON_DEV=true"
            )
            ;;
        node)
            build_args+=(
                "--build-arg" "INCLUDE_NODE=true"
                "--build-arg" "INCLUDE_NODE_DEV=true"
            )
            ;;
        multi)
            build_args+=(
                "--build-arg" "INCLUDE_PYTHON=true"
                "--build-arg" "INCLUDE_PYTHON_DEV=true"
                "--build-arg" "INCLUDE_NODE=true"
                "--build-arg" "INCLUDE_NODE_DEV=true"
            )
            ;;
    esac

    docker build -f "${DOCKERFILE}" -t "${tag}" "${build_args[@]}" "${CONTAINERS_DIR}" > /dev/null 2>&1
    echo "${tag}"
}

# Function to build prod variant
build_prod() {
    local preset="$1"
    local tag="${PROJECT_NAME}:${preset}-prod"

    log_info "Building prod variant: ${preset}"

    local build_args=(
        "--build-arg" "PROJECT_NAME=${PROJECT_NAME}"
        "--build-arg" "BASE_IMAGE=debian:bookworm-slim"
        "--build-arg" "ENABLE_PASSWORDLESS_SUDO=false"
        "--build-arg" "INCLUDE_DEV_TOOLS=false"
    )

    case "$preset" in
        python)
            build_args+=(
                "--build-arg" "INCLUDE_PYTHON=true"
                "--build-arg" "INCLUDE_PYTHON_DEV=false"
            )
            ;;
        node)
            build_args+=(
                "--build-arg" "INCLUDE_NODE=true"
                "--build-arg" "INCLUDE_NODE_DEV=false"
            )
            ;;
        multi)
            build_args+=(
                "--build-arg" "INCLUDE_PYTHON=true"
                "--build-arg" "INCLUDE_PYTHON_DEV=false"
                "--build-arg" "INCLUDE_NODE=true"
                "--build-arg" "INCLUDE_NODE_DEV=false"
            )
            ;;
    esac

    docker build -f "${DOCKERFILE}" -t "${tag}" "${build_args[@]}" "${CONTAINERS_DIR}" > /dev/null 2>&1
    echo "${tag}"
}

# Function to compare sizes
compare_preset() {
    local preset="$1"

    echo ""
    echo -e "${BOLD}${CYAN}=== Comparing ${preset} ===${NC}"
    echo ""

    # Build dev variant
    local dev_tag
    dev_tag=$(build_dev "$preset")

    # Build prod variant
    local prod_tag
    prod_tag=$(build_prod "$preset")

    # Get sizes
    local dev_size
    local prod_size
    dev_size=$(get_image_size "$dev_tag")
    prod_size=$(get_image_size "$prod_tag")

    # Calculate savings
    local diff=$((dev_size - prod_size))
    local percent=0
    if [[ $dev_size -gt 0 ]]; then
        percent=$(( (diff * 100) / dev_size ))
    fi

    # Format sizes
    local dev_formatted
    local prod_formatted
    local diff_formatted
    dev_formatted=$(format_bytes "$dev_size")
    prod_formatted=$(format_bytes "$prod_size")
    diff_formatted=$(format_bytes "$diff")

    # Print comparison table
    printf "${BOLD}%-20s %15s %15s %15s %10s${NC}\n" \
        "Variant" "Dev Size" "Prod Size" "Savings" "% Saved"
    printf "%-20s %15s %15s %15s %10s\n" \
        "${preset}" "$dev_formatted" "$prod_formatted" "$diff_formatted" "${percent}%"

    # Print detailed breakdown
    echo ""
    log_info "Dev image:  ${dev_tag}"
    log_info "Prod image: ${prod_tag}"

    if [[ $percent -ge 30 ]]; then
        log_success "Production image is ${percent}% smaller!"
    elif [[ $percent -ge 15 ]]; then
        log_info "Production image is ${percent}% smaller"
    else
        log_warn "Production image is only ${percent}% smaller (expected 15-40%)"
    fi
}

# Function to cleanup images
cleanup() {
    log_info "Cleaning up test images..."
    docker images --format "{{.Repository}}:{{.Tag}}" | \
        grep "^${PROJECT_NAME}:" | \
        xargs -r docker rmi -f > /dev/null 2>&1 || true
    log_success "Cleanup complete"
}

# Main script
main() {
    local preset="${1:-all}"

    echo -e "${BOLD}${CYAN}"
    echo "========================================="
    echo " Production Image Size Comparison"
    echo "========================================="
    echo -e "${NC}"

    # Verify Docker is available
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    # Verify Dockerfile exists
    if [[ ! -f "${DOCKERFILE}" ]]; then
        log_error "Dockerfile not found: ${DOCKERFILE}"
        exit 1
    fi

    # Run comparisons
    case "$preset" in
        minimal)
            compare_preset "minimal"
            ;;
        python)
            compare_preset "python"
            ;;
        node)
            compare_preset "node"
            ;;
        multi)
            compare_preset "multi"
            ;;
        all)
            compare_preset "minimal"
            compare_preset "python"
            compare_preset "node"
            compare_preset "multi"
            ;;
        *)
            log_error "Unknown preset: $preset"
            echo "Valid presets: minimal, python, node, multi, all"
            exit 1
            ;;
    esac

    # Cleanup
    echo ""
    cleanup

    echo ""
    log_success "Comparison complete!"
}

# Trap cleanup on exit
trap cleanup EXIT

# Run main
main "$@"
