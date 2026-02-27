#!/bin/bash
echo "=== Development Tools Status ==="
echo ""
echo "Version Control:"
for tool in git tig colordiff gh delta lazygit; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

echo ""
echo "Search Tools:"
for tool in rg fd ag ack; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

echo ""
echo "Modern CLI Tools:"
# Check for eza (preferred) or exa (fallback for older Debian)
if command -v eza &> /dev/null; then
    echo "  ✓ eza is installed"
elif command -v exa &> /dev/null; then
    echo "  ✓ exa is installed"
else
    echo "  ✗ eza/exa is not found"
fi

for tool in bat duf htop ncdu fzf; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

echo ""
echo "Development Utilities:"
for tool in direnv entr just mkcert act glab biome taplo; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

echo ""
echo "Cache Configuration:"
echo "  DEV_TOOLS_CACHE: ${DEV_TOOLS_CACHE:-/cache/dev-tools}"
echo "  CAROOT: ${CAROOT:-/cache/dev-tools/mkcert-ca}"
echo "  DIRENV_ALLOW_DIR: ${DIRENV_ALLOW_DIR:-/cache/dev-tools/direnv-allow}"
