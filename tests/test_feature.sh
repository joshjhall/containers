#!/usr/bin/env bash
# Quick feature test script for testing individual features in isolation
#
# This script allows rapid testing of single features during development
# without running full integration test suites.
#
# Usage:
#   ./tests/test_feature.sh <feature_name>
#
# Examples:
#   ./tests/test_feature.sh golang
#   ./tests/test_feature.sh python-dev
#   ./tests/test_feature.sh kubernetes
#   ./tests/test_feature.sh dev-tools
#
# The script will:
#   1. Build a container with only the specified feature
#   2. Verify the feature installed correctly
#   3. Report results

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check arguments
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: Feature name required${NC}"
    echo ""
    echo "Usage: $0 <feature_name> [BUILD_ARGS...]"
    echo ""
    echo "Examples:"
    echo "  $0 golang"
    echo "  $0 golang GO_VERSION=1.24.5"
    echo "  $0 python-dev"
    echo "  $0 kubernetes"
    echo "  $0 dev-tools"
    echo ""
    exit 1
fi

FEATURE="$1"
shift  # Remove feature name, leaving optional build args

# Collect any additional build args
EXTRA_BUILD_ARGS=()
for arg in "$@"; do
    EXTRA_BUILD_ARGS+=("--build-arg" "$arg")
done

# Map feature names to build args
declare -A FEATURE_MAP=(
    ["python"]="INCLUDE_PYTHON"
    ["python-dev"]="INCLUDE_PYTHON_DEV"
    ["node"]="INCLUDE_NODE"
    ["node-dev"]="INCLUDE_NODE_DEV"
    ["rust"]="INCLUDE_RUST"
    ["rust-dev"]="INCLUDE_RUST_DEV"
    ["golang"]="INCLUDE_GOLANG"
    ["golang-dev"]="INCLUDE_GOLANG_DEV"
    ["ruby"]="INCLUDE_RUBY"
    ["ruby-dev"]="INCLUDE_RUBY_DEV"
    ["java"]="INCLUDE_JAVA"
    ["java-dev"]="INCLUDE_JAVA_DEV"
    ["r"]="INCLUDE_R"
    ["r-dev"]="INCLUDE_R_DEV"
    ["kubernetes"]="INCLUDE_KUBERNETES"
    ["terraform"]="INCLUDE_TERRAFORM"
    ["aws"]="INCLUDE_AWS"
    ["gcloud"]="INCLUDE_GCLOUD"
    ["cloudflare"]="INCLUDE_CLOUDFLARE"
    ["docker"]="INCLUDE_DOCKER"
    ["dev-tools"]="INCLUDE_DEV_TOOLS"
    ["ollama"]="INCLUDE_OLLAMA"
    ["op"]="INCLUDE_OP"
    ["postgres-client"]="INCLUDE_POSTGRES_CLIENT"
    ["redis-client"]="INCLUDE_REDIS_CLIENT"
    ["sqlite-client"]="INCLUDE_SQLITE_CLIENT"
)

# Check if feature is valid
if [ -z "${FEATURE_MAP[$FEATURE]:-}" ]; then
    echo -e "${RED}Error: Unknown feature '$FEATURE'${NC}"
    echo ""
    echo "Valid features:"
    for key in "${!FEATURE_MAP[@]}"; do
        echo "  - $key"
    done | sort
    echo ""
    exit 1
fi

BUILD_ARG="${FEATURE_MAP[$FEATURE]}"
IMAGE_NAME="test-feature-${FEATURE}"

echo -e "${BLUE}=== Feature Test: $FEATURE ===${NC}"
echo "Date: $(date)"
echo "Build Arg: $BUILD_ARG=true"
echo "Image: $IMAGE_NAME"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not available${NC}"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    exit 1
fi

# Build the container
echo -e "${BLUE}Building container with $FEATURE...${NC}"
echo ""

BUILD_LOG="/tmp/feature-test-${FEATURE}-$$.log"

if docker build \
    -f "$PROJECT_ROOT/Dockerfile" \
    --build-arg PROJECT_PATH=. \
    --build-arg PROJECT_NAME=test \
    --build-arg "${BUILD_ARG}=true" \
    "${EXTRA_BUILD_ARGS[@]}" \
    -t "$IMAGE_NAME" \
    "$PROJECT_ROOT" > "$BUILD_LOG" 2>&1; then
    echo -e "${GREEN}✓ Build successful${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    echo ""
    echo "Last 50 lines of build log:"
    tail -50 "$BUILD_LOG"
    echo ""
    echo "Full log saved to: $BUILD_LOG"
    exit 1
fi

echo ""

# Verify the feature installed
echo -e "${BLUE}Verifying $FEATURE installation...${NC}"

# Run basic verification based on feature type
case "$FEATURE" in
    golang|golang-dev)
        if docker run --rm "$IMAGE_NAME" which go > /dev/null 2>&1; then
            VERSION=$(docker run --rm "$IMAGE_NAME" go version)
            echo -e "${GREEN}✓ Go installed: $VERSION${NC}"
        else
            echo -e "${RED}✗ Go not found${NC}"
            exit 1
        fi
        ;;

    python|python-dev)
        if docker run --rm "$IMAGE_NAME" which python3 > /dev/null 2>&1; then
            VERSION=$(docker run --rm "$IMAGE_NAME" python3 --version)
            echo -e "${GREEN}✓ Python installed: $VERSION${NC}"
        else
            echo -e "${RED}✗ Python not found${NC}"
            exit 1
        fi
        ;;

    node|node-dev)
        if docker run --rm "$IMAGE_NAME" which node > /dev/null 2>&1; then
            VERSION=$(docker run --rm "$IMAGE_NAME" node --version)
            echo -e "${GREEN}✓ Node installed: $VERSION${NC}"
        else
            echo -e "${RED}✗ Node not found${NC}"
            exit 1
        fi
        ;;

    rust|rust-dev)
        if docker run --rm "$IMAGE_NAME" which rustc > /dev/null 2>&1; then
            VERSION=$(docker run --rm "$IMAGE_NAME" rustc --version)
            echo -e "${GREEN}✓ Rust installed: $VERSION${NC}"
        else
            echo -e "${RED}✗ Rust not found${NC}"
            exit 1
        fi
        ;;

    kubernetes)
        if docker run --rm "$IMAGE_NAME" which kubectl > /dev/null 2>&1; then
            VERSION=$(docker run --rm "$IMAGE_NAME" kubectl version --client --short 2>/dev/null || docker run --rm "$IMAGE_NAME" kubectl version --client)
            echo -e "${GREEN}✓ kubectl installed: $VERSION${NC}"
        else
            echo -e "${RED}✗ kubectl not found${NC}"
            exit 1
        fi
        ;;

    dev-tools)
        TOOLS=("lazygit" "delta" "act" "git-cliff")
        ALL_FOUND=true
        for tool in "${TOOLS[@]}"; do
            if docker run --rm "$IMAGE_NAME" which "$tool" > /dev/null 2>&1; then
                echo -e "${GREEN}✓ $tool installed${NC}"
            else
                echo -e "${RED}✗ $tool not found${NC}"
                ALL_FOUND=false
            fi
        done
        if [ "$ALL_FOUND" = false ]; then
            exit 1
        fi
        ;;

    docker)
        if docker run --rm "$IMAGE_NAME" which docker > /dev/null 2>&1; then
            VERSION=$(docker run --rm "$IMAGE_NAME" docker --version)
            echo -e "${GREEN}✓ Docker installed: $VERSION${NC}"
        else
            echo -e "${RED}✗ Docker not found${NC}"
            exit 1
        fi
        ;;

    *)
        echo -e "${YELLOW}⚠ No specific verification for $FEATURE${NC}"
        echo -e "${GREEN}✓ Build completed successfully${NC}"
        ;;
esac

echo ""
echo -e "${GREEN}=== Feature Test Passed ===${NC}"
echo "Image: $IMAGE_NAME"
echo ""
echo "To run the container interactively:"
echo "  docker run -it --rm $IMAGE_NAME"
echo ""
echo "To remove the test image:"
echo "  docker rmi $IMAGE_NAME"
echo ""

# Clean up build log
rm -f "$BUILD_LOG"

exit 0
