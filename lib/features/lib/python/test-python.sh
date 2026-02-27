#!/bin/bash
echo "=== Python Installation Status ==="
if command -v python3 &> /dev/null; then
    echo "✓ Python3 $(python3 --version) is installed"
    echo "  Binary: $(which python3)"
    echo "  Real path: $(readlink -f "$(which python3)")"
else
    echo "✗ Python3 is not installed"
fi

if command -v python &> /dev/null; then
    echo "✓ Python symlink exists at $(which python)"
fi

echo ""
echo "=== Python Package Managers ==="
for cmd in pip pip3 pipx poetry uv; do
    if command -v $cmd &> /dev/null; then
        version=$($cmd --version 2>&1 | head -1)
        echo "✓ $cmd: $version"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Python Environment ==="
echo "PIP_CACHE_DIR: ${PIP_CACHE_DIR:-not set}"
echo "POETRY_CACHE_DIR: ${POETRY_CACHE_DIR:-not set}"
echo "PIPX_HOME: ${PIPX_HOME:-not set}"

echo ""
echo "=== Installed Python Packages ==="
pip list 2>/dev/null | head -10
echo "..."
total_packages=$(pip list 2>/dev/null | wc -l)
echo "Total packages: $total_packages"
