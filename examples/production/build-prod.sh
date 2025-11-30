#!/usr/bin/env bash
# Production Image Build Helper Script
#
# This script simplifies building production-optimized containers using the
# main Dockerfile with production-focused build arguments.
#
# Usage:
#   ./build-prod.sh minimal [project-name]
#   ./build-prod.sh python [project-name]
#   ./build-prod.sh node [project-name]
#   ./build-prod.sh custom --arg KEY=VALUE ...
#
# Examples:
#   ./build-prod.sh minimal myapp
#   ./build-prod.sh python myapp
#   ./build-prod.sh node myapp --arg NODE_VERSION=18
#   ./build-prod.sh custom --arg INCLUDE_PYTHON=true --arg INCLUDE_NODE=true

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKERFILE="${CONTAINERS_DIR}/Dockerfile"
PROJECT_NAME="${PROJECT_NAME:-myproject}"
BUILD_CONTEXT="${CONTAINERS_DIR}"

# Production base arguments (always applied)
PROD_BASE_ARGS=(
    "BASE_IMAGE=debian:trixie-slim"
    "ENABLE_PASSWORDLESS_SUDO=false"
    "INCLUDE_DEV_TOOLS=false"
)

# Function to print usage
usage() {
    cat << EOF
${BLUE}Production Image Build Helper${NC}

${YELLOW}Usage:${NC}
  $0 <preset> [project-name] [--arg KEY=VALUE ...]

${YELLOW}Presets:${NC}
  minimal      Minimal base with no language runtimes (~200-300MB)
  python       Python runtime without dev tools (~400-500MB)
  node         Node.js runtime without dev tools (~400-500MB)
  custom       Custom configuration via --arg flags

${YELLOW}Options:${NC}
  --arg KEY=VALUE    Additional build argument (can be repeated)
  --context PATH     Build context directory (default: containers dir)
  --help             Show this help message

${YELLOW}Examples:${NC}
  # Build minimal production base
  $0 minimal myapp

  # Build Python production runtime
  $0 python myapp

  # Build Node production runtime with specific version
  $0 node myapp --arg NODE_VERSION=18

  # Build custom multi-runtime production image
  $0 custom myapp \\
    --arg INCLUDE_PYTHON=true \\
    --arg INCLUDE_PYTHON_DEV=false \\
    --arg INCLUDE_NODE=true \\
    --arg INCLUDE_NODE_DEV=false

${YELLOW}Environment Variables:${NC}
  PROJECT_NAME       Project name (default: myproject)
  BUILD_CONTEXT      Docker build context (default: containers dir)

EOF
}

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

# Function to build image
build_image() {
    local preset="$1"
    local project_name="$2"
    shift 2
    local extra_args=()

    # Parse additional arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --arg)
                if [[ $# -lt 2 ]]; then
                    log_error "--arg requires KEY=VALUE"
                    exit 1
                fi
                extra_args+=("$2")
                shift 2
                ;;
            --context)
                if [[ $# -lt 2 ]]; then
                    log_error "--context requires PATH"
                    exit 1
                fi
                BUILD_CONTEXT="$2"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Determine preset-specific arguments
    local preset_args=()
    local tag_suffix=""

    case "$preset" in
        minimal)
            tag_suffix="minimal-prod"
            preset_args=(
                "INCLUDE_PYTHON=false"
                "INCLUDE_NODE=false"
                "INCLUDE_RUST=false"
                "INCLUDE_GOLANG=false"
                "INCLUDE_RUBY=false"
                "INCLUDE_R=false"
                "INCLUDE_JAVA=false"
                "INCLUDE_MOJO=false"
            )
            ;;
        python)
            tag_suffix="python-prod"
            preset_args=(
                "INCLUDE_PYTHON=true"
                "INCLUDE_PYTHON_DEV=false"
                "PYTHON_VERSION=3.12"
                "INCLUDE_NODE=false"
                "INCLUDE_RUST=false"
                "INCLUDE_GOLANG=false"
                "INCLUDE_RUBY=false"
                "INCLUDE_R=false"
                "INCLUDE_JAVA=false"
                "INCLUDE_MOJO=false"
            )
            ;;
        node)
            tag_suffix="node-prod"
            preset_args=(
                "INCLUDE_NODE=true"
                "INCLUDE_NODE_DEV=false"
                "NODE_VERSION=20"
                "INCLUDE_PYTHON=false"
                "INCLUDE_RUST=false"
                "INCLUDE_GOLANG=false"
                "INCLUDE_RUBY=false"
                "INCLUDE_R=false"
                "INCLUDE_JAVA=false"
                "INCLUDE_MOJO=false"
            )
            ;;
        custom)
            tag_suffix="custom-prod"
            # No preset args for custom
            ;;
        *)
            log_error "Unknown preset: $preset"
            usage
            exit 1
            ;;
    esac

    # Combine all build arguments
    local all_args=()
    all_args+=("PROJECT_NAME=${project_name}")
    all_args+=("${PROD_BASE_ARGS[@]}")
    all_args+=("${preset_args[@]}")
    all_args+=("${extra_args[@]}")

    # Build the image tag
    local image_tag="${project_name}:${tag_suffix}"

    # Print build configuration
    log_info "Building production image"
    log_info "  Preset: ${preset}"
    log_info "  Project: ${project_name}"
    log_info "  Image Tag: ${image_tag}"
    log_info "  Dockerfile: ${DOCKERFILE}"
    log_info "  Build Context: ${BUILD_CONTEXT}"
    echo ""
    log_info "Build Arguments:"
    for arg in "${all_args[@]}"; do
        echo "    ${arg}"
    done
    echo ""

    # Build docker command
    local docker_cmd="docker build"
    docker_cmd+=" -f ${DOCKERFILE}"
    docker_cmd+=" -t ${image_tag}"

    for arg in "${all_args[@]}"; do
        docker_cmd+=" --build-arg ${arg}"
    done

    docker_cmd+=" ${BUILD_CONTEXT}"

    # Execute build
    log_info "Executing: ${docker_cmd}"
    echo ""

    if eval "${docker_cmd}"; then
        echo ""
        log_success "Build completed successfully!"
        log_success "Image: ${image_tag}"

        # Show image size
        local size
        size=$(docker images --format "{{.Size}}" "${image_tag}" | head -n1)
        log_info "Image Size: ${size}"

        # Suggest next steps
        echo ""
        log_info "Next steps:"
        echo "  # Run the container"
        echo "  docker run -it --rm ${image_tag}"
        echo ""
        echo "  # Inspect the image"
        echo "  docker inspect ${image_tag}"
        echo ""
        echo "  # Scan for vulnerabilities"
        echo "  docker scan ${image_tag}"
        echo "  # OR with trivy:"
        echo "  trivy image ${image_tag}"
    else
        echo ""
        log_error "Build failed!"
        exit 1
    fi
}

# Main script
main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local preset="$1"
    shift

    # Check for help
    if [[ "$preset" == "--help" ]] || [[ "$preset" == "-h" ]]; then
        usage
        exit 0
    fi

    # Get project name (optional second argument)
    local project_name="${PROJECT_NAME}"
    if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
        project_name="$1"
        shift
    fi

    # Verify Dockerfile exists
    if [[ ! -f "${DOCKERFILE}" ]]; then
        log_error "Dockerfile not found: ${DOCKERFILE}"
        exit 1
    fi

    # Build the image
    build_image "$preset" "$project_name" "$@"
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
