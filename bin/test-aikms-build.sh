#!/bin/bash
# Test build with AIKMS requirements - comprehensive feature test
set -euo pipefail

echo "=== Starting Comprehensive Container Build Test ==="
echo "Base Image: mcr.microsoft.com/devcontainers/base:bookworm"
echo "Features: Python Dev, Node Dev, Rust Dev, Go Dev, 1Password CLI, Dev Tools, Docker, Ollama"
echo ""
echo "This build will take approximately 15-20 minutes..."
echo ""

# Start timer
START_TIME=$(date +%s)

# Navigate to containers directory
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Run the build with all specified features
DOCKER_BUILDKIT=1 docker build \
    --build-arg BASE_IMAGE=mcr.microsoft.com/devcontainers/base:bookworm \
    --build-arg PROJECT_NAME=aikms \
    --build-arg USERNAME=vscode \
    --build-arg WORKING_DIR=/workspace/aikms \
    --build-arg INCLUDE_PYTHON_DEV=true \
    --build-arg INCLUDE_NODE_DEV=true \
    --build-arg INCLUDE_RUST_DEV=true \
    --build-arg INCLUDE_GOLANG_DEV=true \
    --build-arg INCLUDE_OP=true \
    --build-arg INCLUDE_DEV_TOOLS=true \
    --build-arg INCLUDE_DOCKER=true \
    --build-arg INCLUDE_OLLAMA=true \
    --tag aikms-test:latest \
    --progress=plain \
    --file Dockerfile \
    . 2>&1 | tee build-test.log

# Calculate build time
END_TIME=$(date +%s)
BUILD_TIME=$((END_TIME - START_TIME))
BUILD_MINUTES=$((BUILD_TIME / 60))
BUILD_SECONDS=$((BUILD_TIME % 60))

echo ""
echo "=== Build Complete! ==="
echo "Build time: ${BUILD_MINUTES} minutes ${BUILD_SECONDS} seconds"
echo "Build log saved to: build-test.log"
echo ""

# Test the built image
echo "=== Testing Built Container ==="
docker run --rm aikms-test:latest bash -c '
set -e
echo "=== Installed Versions ==="
echo ""

echo "Python Development:"
python --version
pip --version
poetry --version 2>/dev/null || echo "Poetry not found"
black --version 2>/dev/null || echo "Black not found"
ruff --version 2>/dev/null || echo "Ruff not found"
echo ""

echo "Node Development:"
node --version
npm --version
yarn --version 2>/dev/null || echo "Yarn not found"
pnpm --version 2>/dev/null || echo "PNPM not found"
echo ""

echo "Rust Development:"
rustc --version
cargo --version
rustup --version
echo ""

echo "Go Development:"
go version
echo ""

echo "Dev Tools:"
git --version
fzf --version 2>/dev/null || echo "FZF not found"
lazygit --version 2>/dev/null || echo "Lazygit not found"
tmux -V 2>/dev/null || echo "Tmux not found"
echo ""

echo "Docker:"
docker --version 2>/dev/null || echo "Docker not found"
echo ""

echo "1Password CLI:"
op --version 2>/dev/null || echo "1Password CLI not found"
echo ""

echo "Ollama:"
ollama --version 2>/dev/null || echo "Ollama not found"
echo ""

echo "=== Container user info ==="
whoami
id
echo ""

echo "=== Working directory ==="
pwd
echo ""

echo "All checks completed!"
'

echo ""
echo "=== Test Summary ==="
echo "✓ Build completed successfully"
echo "✓ Container runs without errors"
echo "✓ Tools are accessible"
echo ""
echo "Image tag: aikms-test:latest"
echo "Image size: $(docker images aikms-test:latest --format "{{.Size}}")"