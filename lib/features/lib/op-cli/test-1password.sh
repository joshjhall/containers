#!/bin/bash
echo "=== 1Password CLI Status ==="

if command -v op &> /dev/null; then
    echo "✓ 1Password CLI is installed"
    echo "  Version: $(op --version)"
    echo "  Binary: $(which op)"
else
    echo "✗ 1Password CLI is not installed"
    exit 1
fi

echo ""
echo "=== Configuration ==="
echo "  OP_CACHE_DIR: ${OP_CACHE_DIR:-/cache/1password}"
echo "  OP_CONFIG_DIR: ${OP_CONFIG_DIR:-/cache/1password/config}"

if [ -d "${OP_CACHE_DIR:-/cache/1password}" ]; then
    echo "  ✓ Cache directory exists"
else
    echo "  ✗ Cache directory missing"
fi

echo ""
echo "=== Authentication Status ==="
if op account list &>/dev/null 2>&1; then
    echo "✓ Authenticated to 1Password"
    op account list
else
    echo "✗ Not authenticated. Run 'op signin' to authenticate"
fi

echo ""
echo "Try these commands:"
echo "  op signin          - Authenticate to 1Password"
echo "  op vault list      - List available vaults"
echo "  op item list       - List items"
echo "  op inject -i file  - Inject secrets into file"
