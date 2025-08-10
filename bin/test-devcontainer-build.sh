#!/bin/bash
# Test the devcontainer build specifically with mcr.microsoft.com/devcontainers/base:bookworm
set -euo pipefail

# Test directory
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TEST_DIR"

echo "=== Testing Devcontainer Build ==="
echo "Base Image: mcr.microsoft.com/devcontainers/base:bookworm"
echo "Features: Python Dev + Node Dev + Dev Tools"
echo ""

# Build with just the essential features that were causing issues
DOCKER_BUILDKIT=1 docker build \
    --build-arg BASE_IMAGE=mcr.microsoft.com/devcontainers/base:bookworm \
    --build-arg PROJECT_NAME=test-project \
    --build-arg USERNAME=vscode \
    --build-arg WORKING_DIR=/workspace/test-project \
    --build-arg INCLUDE_PYTHON_DEV=true \
    --build-arg INCLUDE_NODE_DEV=true \
    --build-arg INCLUDE_DEV_TOOLS=true \
    --build-arg INCLUDE_DOCKER=true \
    --target base \
    --tag devcontainer-test:latest \
    --progress=plain \
    --file Dockerfile \
    .

echo ""
echo "=== Build Complete! Testing container... ==="

# Test the container
docker run --rm devcontainer-test:latest bash -c '
set -e
echo "=== Checking for syntax errors in bashrc.d scripts ==="
for script in /etc/bashrc.d/*.sh; do
    echo -n "Checking $script... "
    if bash -n "$script"; then
        echo "OK"
    else
        echo "SYNTAX ERROR!"
        exit 1
    fi
done

echo ""
echo "=== Testing Python tools ==="
echo -n "Python: "
python --version || echo "NOT FOUND"
echo -n "pip: "
pip --version || echo "NOT FOUND"
echo -n "pytest: "
pytest --version || echo "NOT FOUND"
echo -n "pytest-asyncio: "
python -c "import pytest_asyncio; print(pytest_asyncio.__version__)" 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== Testing Node.js tools ==="
echo -n "Node: "
node --version || echo "NOT FOUND"
echo -n "npm: "
npm --version || echo "NOT FOUND"

echo ""
echo "=== Testing Claude Code ==="
echo -n "Claude: "
claude --version 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== Testing shell functions ==="
# Source bashrc to load functions
source /etc/bash.bashrc 2>/dev/null || true
# Test if node-clean function is defined
if type -t node-clean >/dev/null 2>&1; then
    echo "node-clean function: DEFINED"
else
    echo "node-clean function: NOT FOUND"
fi
'

echo ""
echo "=== Test Complete! ==="
